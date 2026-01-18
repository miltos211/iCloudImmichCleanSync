#!/usr/bin/env python3
"""
Photo Sync Orchestrator
Coordinates export from iCloud Photo Library and upload to Immich
"""

import argparse
import configparser
import json
import os
import signal
import sqlite3
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Tuple
import shutil
import glob

import requests
from dotenv import load_dotenv
from rich.console import Console
from rich.progress import (
    Progress, SpinnerColumn, BarColumn, TextColumn, 
    TimeRemainingColumn, MofNCompleteColumn
)

# Import our custom logging module  
lib_path = str(Path(__file__).parent / ".lib")
if lib_path not in sys.path:
    sys.path.insert(0, lib_path)

# Import from our custom logging module (avoid conflict with stdlib logging)
import importlib.util
spec = importlib.util.spec_from_file_location("custom_logging", Path(__file__).parent / ".lib" / "logging.py")
custom_logging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(custom_logging)

create_logger = custom_logging.create_logger


class StateDB:
    """SQLite database manager for sync state tracking"""
    
    def __init__(self, db_path: Path):
        self.db_path = db_path
        self.conn = None
        self._init_database()
    
    def _init_database(self):
        """Initialize database with required schema"""
        self.conn = sqlite3.connect(str(self.db_path))
        self.conn.row_factory = sqlite3.Row
        
        # Create tables if they don't exist
        self.conn.executescript("""
            CREATE TABLE IF NOT EXISTS sync_metadata (
                key TEXT PRIMARY KEY,
                value TEXT
            );
            
            CREATE TABLE IF NOT EXISTS assets (
                asset_id TEXT PRIMARY KEY,
                original_filename TEXT,
                asset_type TEXT,
                creation_date TEXT,
                status TEXT DEFAULT 'pending',
                immich_id TEXT,
                error_message TEXT,
                retry_count INTEGER DEFAULT 0,
                processed_at TEXT,
                file_size INTEGER,
                duration REAL,
                upload_bytes INTEGER,
                upload_duration REAL
            );
            
            CREATE INDEX IF NOT EXISTS idx_status ON assets(status);
            CREATE INDEX IF NOT EXISTS idx_retry ON assets(status, retry_count);
        """)
        self.conn.commit()
    
    def add_assets(self, assets: List[Dict]):
        """Bulk insert assets from Swift list-assets response"""
        assets_data = [
            (
                asset['id'],
                asset.get('original_filename', ''),
                asset['type'],
                asset['creation_date'],
                'pending'
            )
            for asset in assets
        ]
        
        self.conn.executemany(
            "INSERT OR IGNORE INTO assets (asset_id, original_filename, asset_type, creation_date, status) VALUES (?, ?, ?, ?, ?)",
            assets_data
        )
        self.conn.commit()
    
    def get_pending_assets(self, max_retries: int = 3) -> List[sqlite3.Row]:
        """Get assets that need processing"""
        cursor = self.conn.execute(
            "SELECT * FROM assets WHERE status='pending' OR (status='failed' AND retry_count < ?) ORDER BY creation_date ASC",
            (max_retries,)
        )
        return cursor.fetchall()
    
    def mark_completed(self, asset_id: str, immich_id: str, file_size: int, upload_bytes: int, upload_duration: float):
        """Mark asset as successfully completed"""
        self.conn.execute(
            """UPDATE assets SET 
               status='completed', immich_id=?, file_size=?, upload_bytes=?, upload_duration=?, processed_at=?
               WHERE asset_id=?""",
            (immich_id, file_size, upload_bytes, upload_duration, datetime.now().isoformat(), asset_id)
        )
        self.conn.commit()
    
    def mark_failed(self, asset_id: str, error_message: str):
        """Mark asset as failed and increment retry count"""
        self.conn.execute(
            "UPDATE assets SET status='failed', error_message=?, retry_count=retry_count+1, processed_at=? WHERE asset_id=?",
            (error_message, datetime.now().isoformat(), asset_id)
        )
        self.conn.commit()
    
    def get_stats(self) -> Dict[str, int]:
        """Get processing statistics"""
        cursor = self.conn.execute(
            "SELECT status, COUNT(*) as count FROM assets GROUP BY status"
        )
        stats = {row['status']: row['count'] for row in cursor.fetchall()}
        
        # Ensure all statuses are present
        for status in ['pending', 'completed', 'failed']:
            stats.setdefault(status, 0)
        
        cursor = self.conn.execute("SELECT COUNT(*) as total FROM assets")
        stats['total'] = cursor.fetchone()['total']
        
        return stats
    
    def set_metadata(self, key: str, value: str):
        """Set metadata value"""
        self.conn.execute(
            "INSERT OR REPLACE INTO sync_metadata (key, value) VALUES (?, ?)",
            (key, value)
        )
        self.conn.commit()
    
    def get_metadata(self, key: str) -> Optional[str]:
        """Get metadata value"""
        cursor = self.conn.execute(
            "SELECT value FROM sync_metadata WHERE key=?", (key,)
        )
        row = cursor.fetchone()
        return row['value'] if row else None
    
    def backup_database(self) -> Path:
        """Create timestamped backup of database"""
        timestamp = datetime.now().strftime('%Y-%m-%d_%H-%M-%S')
        backup_path = self.db_path.parent / f"state_backup_{timestamp}.db"
        shutil.copy2(self.db_path, backup_path)
        
        # Keep only last 5 backups
        backups = sorted(glob.glob(str(self.db_path.parent / 'state_backup_*.db')))
        for old_backup in backups[:-5]:
            os.remove(old_backup)
        
        return backup_path
    
    def close(self):
        """Close database connection"""
        if self.conn:
            self.conn.close()


class PhotoSyncOrchestrator:
    """Main orchestrator for photo synchronization"""
    
    def __init__(self, args):
        self.args = args
        self.config = self._load_config()
        self.logger = self._setup_logging()
        self.db = None
        self.shutdown_requested = False
        
        # Setup signal handlers for graceful shutdown
        signal.signal(signal.SIGINT, self._signal_handler)
        signal.signal(signal.SIGTERM, self._signal_handler)
    
    def _signal_handler(self, signum, frame):
        """Handle shutdown signals gracefully"""
        self.logger.info("\n🛑 Shutdown signal received. Finishing current asset...")
        self.shutdown_requested = True
    
    def _load_config(self) -> configparser.ConfigParser:
        """Load configuration from files"""
        load_dotenv()  # Load .env file
        
        config = configparser.ConfigParser()
        config.read('config.cfg')
        
        # Validate required environment variables
        api_url = os.getenv("IMMICH_API_URL")
        api_key = os.getenv("IMMICH_API_KEY")
        
        if not api_url or not api_key:
            raise ValueError("IMMICH_API_URL and IMMICH_API_KEY must be set in .env file")
        
        return config
    
    def _setup_logging(self):
        """Setup logging using our custom logging module"""
        # Determine quiet mode based on log level
        quiet_mode = self.args.log_level.upper() in ['WARNING', 'ERROR']
        
        # Create logger using our custom module
        logger = create_logger("photo-sync", quiet=quiet_mode)
        
        # Set log level on the logger itself
        import logging
        logger.logger.setLevel(getattr(logging, self.args.log_level.upper()))
        
        return logger
    
    def _validate_environment(self):
        """Validate environment and dependencies"""
        self.logger.info("🔍 Validating environment...")
        
        # Check Swift binary
        swift_binary = Path(self.config['paths']['swift_binary'])
        if not swift_binary.exists():
            raise FileNotFoundError(f"Swift binary not found: {swift_binary}")
        
        if not os.access(swift_binary, os.X_OK):
            raise PermissionError(f"Swift binary not executable: {swift_binary}")
        
        # Test Immich API connection
        try:
            api_url = os.getenv("IMMICH_API_URL")
            api_key = os.getenv("IMMICH_API_KEY")
            
            response = requests.get(
                f"{api_url}/api-keys",
                headers={"x-api-key": api_key},
                timeout=10
            )
            response.raise_for_status()
            self.logger.success("Immich API connection successful")
            
        except Exception as e:
            raise ConnectionError(f"Failed to connect to Immich API: {e}")
        
        # Create temp directory
        temp_dir = Path(self.config['paths']['temp_dir'])
        temp_dir.mkdir(exist_ok=True)
        
        self.logger.success("Environment validation complete")
    
    def _call_swift_binary(self, args: List[str]) -> Dict:
        """Call Swift binary and parse JSON response"""
        swift_binary = Path(self.config['paths']['swift_binary'])
        cmd = [str(swift_binary)] + args
        
        self.logger.debug(f"Calling Swift: {' '.join(cmd)}")
        
        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                check=True,
                timeout=120
            )
            
            self.logger.debug(f"Swift stdout: {result.stdout}")
            return json.loads(result.stdout)
            
        except subprocess.CalledProcessError as e:
            self.logger.debug(f"Swift stderr: {e.stderr}")
            raise
        except subprocess.TimeoutExpired:
            raise TimeoutError("Swift binary timed out")
        except json.JSONDecodeError as e:
            raise ValueError(f"Invalid JSON from Swift binary: {e}")
    
    def _discover_assets(self):
        """Discover assets using Swift binary"""
        self.logger.info("Discovering assets from iCloud Photo Library...")
        
        # Build Swift command based on args
        swift_args = ['list-assets']
        
        if self.args.type != 'all':
            swift_args.extend(['--type', self.args.type])
        
        if self.args.no_screenshots:
            swift_args.append('--no-screenshots')
        elif self.args.screenshots_only:
            swift_args.append('--screenshots-only')
        
        # Call Swift binary
        assets = self._call_swift_binary(swift_args)
        
        if not isinstance(assets, list):
            raise ValueError("Expected list of assets from Swift binary")
        
        # Add to database
        self.db.add_assets(assets)
        
        # Set metadata
        self.db.set_metadata('started_at', datetime.now().isoformat())
        self.db.set_metadata('total_assets', str(len(assets)))
        self.db.set_metadata('asset_types', self.args.type)
        self.db.set_metadata('include_screenshots', str(not self.args.no_screenshots))
        
        # Count by type
        image_count = len([a for a in assets if a['type'] == 'image'])
        video_count = len([a for a in assets if a['type'] == 'video'])
        
        self.logger.info(f"Found {len(assets)} assets ({image_count} images, {video_count} videos)")
        
        return len(assets)
    
    def _upload_to_immich(self, file_path: Path, metadata: Dict) -> Tuple[str, int, float]:
        """Upload asset to Immich with metadata"""
        api_url = os.getenv("IMMICH_API_URL")
        api_key = os.getenv("IMMICH_API_KEY")
        timeout = int(self.config['upload']['upload_timeout'])
        
        url = f"{api_url}/assets"
        headers = {"x-api-key": api_key}
        
        file_size = file_path.stat().st_size
        start_time = time.time()
        
        with open(file_path, 'rb') as f:
            files = {'assetData': f}
            data = {
                'deviceAssetId': metadata.get('asset_id', str(file_path)),
                'deviceId': 'photo-sync-script',
                'filename': metadata['original_filename'],
                'fileCreatedAt': metadata['creation_date'],
                'fileModifiedAt': metadata.get('modification_date', metadata['creation_date']),
                'isFavorite': 'true' if metadata.get('is_favorite', False) else 'false',
            }
            
            # Add duration for videos
            if metadata.get('duration'):
                data['duration'] = str(metadata['duration'])
            
            # Add GPS coordinates as direct fields (not in metadata array)
            if metadata.get('location'):
                data['latitude'] = metadata['location']['latitude']
                data['longitude'] = metadata['location']['longitude']
            
            # Note: Camera info goes in EXIF metadata, not custom metadata
            # Immich extracts this from the actual image file automatically
            
            self.logger.debug(f"Uploading {file_path.name} ({file_size / 1024 / 1024:.1f} MB)")
            self.logger.debug(f"Upload data: {data}")
            
            response = requests.post(url, headers=headers, files=files, data=data, timeout=timeout)
            
            # Log response details on error
            if response.status_code >= 400:
                self.logger.debug(f"Error response status: {response.status_code}")
                self.logger.debug(f"Error response headers: {response.headers}")
                self.logger.debug(f"Error response body: {response.text}")
            
            response.raise_for_status()
            
            upload_duration = time.time() - start_time
            bandwidth = (file_size / upload_duration) / (1024 * 1024)  # MB/s
            
            self.logger.debug(f"Upload complete: {bandwidth:.1f} MB/s")
            
            result = response.json()
            return result['id'], file_size, upload_duration
    
    def _process_asset_with_retries(self, asset: sqlite3.Row, progress_task) -> bool:
        """Process single asset with exponential backoff retry logic"""
        max_retries = int(self.config['retry']['max_retries'])
        retry_delays = [int(x.strip()) for x in self.config['retry']['retry_delays'].split(',')]
        temp_dir = Path(self.config['paths']['temp_dir'])
        
        asset_id = asset['asset_id']
        
        for attempt in range(max_retries):
            try:
                self.logger.debug(f"Processing asset {asset_id} (attempt {attempt + 1}/{max_retries})")
                
                # Export from iCloud
                export_result = self._call_swift_binary(['export-asset', asset_id, str(temp_dir)])
                
                if not export_result.get('success'):
                    raise ValueError(f"Swift export failed: {export_result}")
                
                file_path = Path(export_result['file_path'])
                metadata = export_result['metadata']
                metadata['asset_id'] = asset_id  # Add for Immich
                
                # Upload to Immich
                immich_id, file_size, upload_duration = self._upload_to_immich(file_path, metadata)
                
                # Cleanup temp file
                try:
                    file_path.unlink()
                    self.logger.debug(f"Deleted temp file: {file_path}")
                except Exception as e:
                    self.logger.warning(f"Failed to delete temp file {file_path}: {e}")
                
                # Mark as completed
                self.db.mark_completed(asset_id, immich_id, file_size, file_size, upload_duration)
                
                self.logger.success(f"Uploaded {metadata['original_filename']}")
                return True
                
            except Exception as e:
                self.logger.debug(f"Attempt {attempt + 1} failed: {e}")
                
                if attempt < max_retries - 1:
                    delay = retry_delays[min(attempt, len(retry_delays) - 1)] / 1000.0  # Convert to seconds
                    self.logger.warning(f"Failed to process {asset_id}: {e} (retry {attempt + 1}/{max_retries} in {delay * 1000:.0f}ms)")
                    time.sleep(delay)
                else:
                    # Final failure
                    self.db.mark_failed(asset_id, str(e))
                    self.logger.error(f"Failed to process {asset_id} after {max_retries} attempts: {e}")
                    return False
        
        return False
    
    def _process_assets(self):
        """Process all pending assets"""
        max_retries = int(self.config['retry']['max_retries'])
        pending_assets = self.db.get_pending_assets(max_retries)
        
        if not pending_assets:
            self.logger.success("No assets to process")
            return
        
        self.logger.info(f"🔄 Processing {len(pending_assets)} assets...")
        
        console = Console()
        
        with Progress(
            SpinnerColumn(),
            TextColumn("[bold blue]{task.description}"),
            BarColumn(),
            MofNCompleteColumn(),
            TextColumn("•"),
            TextColumn("[cyan]{task.completed}/{task.total}"),
            TextColumn("•"),
            TextColumn("[green]{task.fields[speed]:.1f} assets/min"),
            TextColumn("•"),
            TimeRemainingColumn(),
            transient=False,
            console=console
        ) as progress:
            
            task = progress.add_task("Processing assets", total=len(pending_assets), speed=0.0)
            start_time = time.time()
            
            for i, asset in enumerate(pending_assets):
                if self.shutdown_requested:
                    self.logger.warning("Graceful shutdown requested. Stopping processing.")
                    break
                
                # Update progress description
                progress.update(task, description=f"Processing {asset['original_filename'] or asset['asset_id']}")
                
                # Process asset
                success = self._process_asset_with_retries(asset, task)
                
                # Calculate speed
                elapsed = time.time() - start_time
                processed_count = i + 1
                speed = (processed_count / elapsed) * 60 if elapsed > 0 else 0.0  # assets per minute
                
                # Update progress with speed
                progress.update(task, advance=1, speed=speed)
                
                # Log speed every 10 assets at INFO level
                if processed_count % 10 == 0:
                    self.logger.info(f"Speed: {speed:.1f} assets/min | Progress: {processed_count}/{len(pending_assets)} ({processed_count/len(pending_assets)*100:.1f}%)")
                
                # Update progress in DB periodically
                update_interval = int(self.config['processing']['progress_update_interval'])
                if (i + 1) % update_interval == 0:
                    stats = self.db.get_stats()
                    progress_percent = (stats['completed'] / stats['total']) * 100 if stats['total'] > 0 else 0
                    self.db.set_metadata('progress_percent', f"{progress_percent:.2f}")
                    self.db.set_metadata('last_progress_update', datetime.now().isoformat())
    
    def _print_summary(self):
        """Print final processing summary"""
        stats = self.db.get_stats()
        
        self.logger.info("\n" + "=" * 40)
        self.logger.info("Photo Sync Complete")
        self.logger.info("=" * 40)
        self.logger.info(f"Total assets: {stats['total']:,}")
        self.logger.info(f"✅ Completed:  {stats['completed']:,}")
        self.logger.info(f"❌ Failed:     {stats['failed']:,}")
        self.logger.info(f"⏳ Pending:    {stats['pending']:,}")
        self.logger.info("=" * 40)
        
        if stats['failed'] > 0:
            self.logger.info("Run with --resume to retry failed assets")
        
        # Set final metadata
        self.db.set_metadata('last_updated', datetime.now().isoformat())
        
        return 0 if stats['failed'] == 0 else 1
    
    def run(self):
        """Main execution flow"""
        try:
            self.logger.info("Starting photo sync orchestrator...")
            
            # Validate environment
            self._validate_environment()
            
            # Initialize database
            db_path = Path(self.config['paths']['state_file'])
            
            # Create backup if resuming and database exists
            if self.args.resume and db_path.exists():
                self.db = StateDB(db_path)
                backup_path = self.db.backup_database()
                self.logger.info(f"Database backed up to: {backup_path}")
            else:
                # Fresh start or reset
                if self.args.reset and db_path.exists():
                    self.logger.info("Resetting database...")
                    db_path.unlink()
                
                self.db = StateDB(db_path)
            
            # Asset discovery phase
            if not self.args.resume or self.db.get_metadata('total_assets') is None:
                total_assets = self._discover_assets()
            else:
                total_assets = int(self.db.get_metadata('total_assets'))
                stats = self.db.get_stats()
                self.logger.info(f"Resuming... {stats['completed']}/{total_assets} already processed")
            
            # Dry run check
            if self.args.dry_run:
                self.logger.info("Dry run mode - no actual processing performed")
                return 0
            
            # Processing phase
            self._process_assets()
            
            # Print summary and return exit code
            return self._print_summary()
            
        except KeyboardInterrupt:
            self.logger.warning("Interrupted by user")
            return 1
        except Exception as e:
            self.logger.error(f"Fatal error: {e}")
            # For debug details, let's just log the exception string for now
            import traceback
            self.logger.debug(f"Exception traceback: {traceback.format_exc()}")
            return 2
        finally:
            if self.db:
                self.db.close()


def main():
    """Main entry point"""
    parser = argparse.ArgumentParser(
        description="Orchestrate photo sync from iCloud to Immich",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s --reset --type image --log-level DEBUG
  %(prog)s --resume
  %(prog)s --type video --workers 5
        """
    )
    
    parser.add_argument('--log-level', choices=['DEBUG', 'INFO', 'WARNING', 'ERROR'], 
                       default='INFO', help='Logging verbosity')
    parser.add_argument('--type', choices=['image', 'video', 'all'], 
                       default='all', help='Asset types to process')
    parser.add_argument('--screenshots-only', action='store_true',
                       help='Process only screenshots')
    parser.add_argument('--no-screenshots', action='store_true', default=True,
                       help='Exclude screenshots (default)')
    parser.add_argument('--workers', type=int, default=1,
                       help='Number of parallel workers (future feature)')
    parser.add_argument('--resume', action='store_true',
                       help='Resume from existing state.db')
    parser.add_argument('--reset', action='store_true',
                       help='Clear state.db and start fresh')
    parser.add_argument('--dry-run', action='store_true',
                       help='List what would be processed without uploading')
    
    args = parser.parse_args()
    
    # Validate argument combinations
    if args.screenshots_only and args.no_screenshots:
        parser.error("Cannot use both --screenshots-only and --no-screenshots")
    
    if args.resume and args.reset:
        parser.error("Cannot use both --resume and --reset")
    
    # Run orchestrator
    orchestrator = PhotoSyncOrchestrator(args)
    sys.exit(orchestrator.run())


if __name__ == '__main__':
    main()
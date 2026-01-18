import subprocess
import json
import tempfile
import shutil
from pathlib import Path
import time

def run_swift_command(args: list, expect_success=True, timeout=60):
    """
    Execute photo-exporter with given arguments
    Returns: JSON result if success expected, (exit_code, stderr) if not
    """
    binary = Path('.lib/photo-exporter')
    if not binary.exists():
        raise FileNotFoundError(f"Swift binary not found: {binary}")
    
    try:
        result = subprocess.run(
            [str(binary)] + args,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=expect_success
        )
        
        if expect_success:
            if result.stdout.strip():
                return json.loads(result.stdout)
            else:
                raise ValueError("Empty output from command")
        else:
            return result.returncode, result.stderr
            
    except subprocess.CalledProcessError as e:
        if expect_success:
            raise AssertionError(f"Command failed with exit code {e.returncode}. Stdout: {e.stdout}. Stderr: {e.stderr}")
        return e.returncode, e.stderr
    except json.JSONDecodeError as e:
        raise AssertionError(f"Invalid JSON output: {result.stdout}")
    except subprocess.TimeoutExpired:
        raise AssertionError(f"Command timed out after {timeout} seconds")

def create_temp_export_dir():
    """Create temporary directory for export tests"""
    return tempfile.mkdtemp(prefix='swift_export_test_')

def cleanup_temp_dir(temp_dir):
    """Clean up temporary test directory"""
    if Path(temp_dir).exists():
        shutil.rmtree(temp_dir)

def validate_asset_schema(asset_data):
    """Validate list-assets JSON schema"""
    required_fields = ['id', 'type', 'creation_date', 'is_screenshot', 'is_live_photo']
    for field in required_fields:
        assert field in asset_data, f"Missing required field: {field}"
    
    assert asset_data['type'] in ['image', 'video'], f"Invalid type: {asset_data['type']}"
    assert isinstance(asset_data['is_screenshot'], bool), f"is_screenshot must be boolean, got {type(asset_data['is_screenshot'])}"
    assert isinstance(asset_data['is_live_photo'], bool), f"is_live_photo must be boolean, got {type(asset_data['is_live_photo'])}"
    
    # Validate ID format (should be like "ABC123/L0/001")
    assert '/' in asset_data['id'], f"Invalid ID format: {asset_data['id']}"
    
    # Validate date format (should be ISO 8601)
    assert 'T' in asset_data['creation_date'], f"Invalid date format: {asset_data['creation_date']}"
    assert asset_data['creation_date'].endswith('Z'), f"Date should end with Z: {asset_data['creation_date']}"

def validate_export_schema(export_data):
    """Validate export-asset JSON schema"""
    assert 'success' in export_data, "Missing 'success' field"
    assert export_data['success'] is True, f"Expected success=True, got {export_data['success']}"
    assert 'file_path' in export_data, "Missing 'file_path' field"
    assert 'metadata' in export_data, "Missing 'metadata' field"
    
    # Validate file path exists
    file_path = Path(export_data['file_path'])
    assert file_path.exists(), f"Exported file does not exist: {file_path}"
    assert file_path.is_file(), f"Export path is not a file: {file_path}"
    
    metadata = export_data['metadata']
    required_metadata = [
        'original_filename', 'creation_date', 'file_size',
        'is_live_photo', 'media_type', 'dimensions', 'format'
    ]
    for field in required_metadata:
        assert field in metadata, f"Missing metadata field: {field}"
    
    # live_photo_video_complement is optional and may be omitted when null
    # but if present, should be null for our current implementation
    
    # Validate metadata types
    assert isinstance(metadata['file_size'], int), f"file_size must be int, got {type(metadata['file_size'])}"
    assert metadata['file_size'] > 0, f"file_size must be positive, got {metadata['file_size']}"
    assert isinstance(metadata['is_live_photo'], bool), f"is_live_photo must be bool"
    assert metadata['media_type'] in ['image', 'video'], f"Invalid media_type: {metadata['media_type']}"
    
    # Validate dimensions
    dimensions = metadata['dimensions']
    assert 'width' in dimensions and 'height' in dimensions, "Missing width/height in dimensions"
    assert isinstance(dimensions['width'], int) and isinstance(dimensions['height'], int), "Dimensions must be integers"
    assert dimensions['width'] > 0 and dimensions['height'] > 0, "Dimensions must be positive"

def validate_error_schema(error_data, expected_code=None):
    """Validate error response JSON schema"""
    assert 'success' in error_data, "Missing 'success' field in error"
    assert error_data['success'] is False, f"Expected success=False in error, got {error_data['success']}"
    assert 'error' in error_data, "Missing 'error' field"
    assert 'error_code' in error_data, "Missing 'error_code' field"
    
    assert isinstance(error_data['error'], str), f"Error message must be string, got {type(error_data['error'])}"
    assert isinstance(error_data['error_code'], int), f"Error code must be int, got {type(error_data['error_code'])}"
    assert len(error_data['error']) > 0, "Error message cannot be empty"
    
    if expected_code is not None:
        assert error_data['error_code'] == expected_code, f"Expected error code {expected_code}, got {error_data['error_code']}"

def measure_performance(func, *args, **kwargs):
    """Measure execution time of a function"""
    start_time = time.time()
    result = func(*args, **kwargs)
    duration = time.time() - start_time
    return result, duration

def count_assets_by_type(assets, asset_type):
    """Count assets of specific type"""
    return len([asset for asset in assets if asset['type'] == asset_type])

def find_live_photos(assets):
    """Find Live Photo assets in asset list"""
    return [asset for asset in assets if asset['is_live_photo']]

def find_screenshots(assets):
    """Find screenshot assets in asset list"""
    return [asset for asset in assets if asset['is_screenshot']]

def get_asset_by_type(assets, asset_type, count=1):
    """Get assets of specific type"""
    filtered = [asset for asset in assets if asset['type'] == asset_type]
    return filtered[:count] if count > 1 else (filtered[0] if filtered else None)
import pytest
import os
from pathlib import Path
from swift_test_helpers import (
    run_swift_command, validate_asset_schema, validate_export_schema, 
    validate_error_schema, measure_performance, count_assets_by_type,
    find_live_photos, find_screenshots, get_asset_by_type
)
from test_fixtures import (
    sample_assets, image_assets, video_assets, temp_export_dir,
    image_assets_no_screenshots, screenshot_assets, small_asset_list,
    live_photo_assets, regular_photo_assets
)

class TestListAssets:
    """Test list-assets command functionality"""
    
    def test_list_all_assets_basic(self, sample_assets):
        """Test basic list-assets execution"""
        assert isinstance(sample_assets, list), "Response should be a list"
        
        if sample_assets:  # Only validate if assets exist
            validate_asset_schema(sample_assets[0])
            print(f"Found {len(sample_assets)} total assets")
    
    def test_list_assets_type_image(self, image_assets):
        """Test --type image filter"""
        for asset in image_assets:
            assert asset['type'] == 'image', f"Expected image type, got {asset['type']}"
            validate_asset_schema(asset)
        
        if image_assets:
            print(f"Found {len(image_assets)} image assets")
    
    def test_list_assets_type_video(self, video_assets):
        """Test --type video filter"""
        for asset in video_assets:
            assert asset['type'] == 'video', f"Expected video type, got {asset['type']}"
            validate_asset_schema(asset)
        
        if video_assets:
            print(f"Found {len(video_assets)} video assets")
    
    def test_no_screenshots_filter(self, image_assets_no_screenshots):
        """Test --no-screenshots excludes screenshots"""
        for asset in image_assets_no_screenshots:
            assert asset['is_screenshot'] is False, f"Found screenshot when excluded: {asset['id']}"
        
        print(f"Found {len(image_assets_no_screenshots)} non-screenshot images")
    
    def test_screenshots_only_filter(self, screenshot_assets):
        """Test --screenshots-only includes only screenshots"""
        for asset in screenshot_assets:
            assert asset['is_screenshot'] is True, f"Found non-screenshot when filtering for screenshots: {asset['id']}"
        
        print(f"Found {len(screenshot_assets)} screenshot assets")
    
    def test_invalid_type_argument(self):
        """Test invalid --type argument handling"""
        exit_code, stderr = run_swift_command(
            ['list-assets', '--type', 'invalid'], 
            expect_success=False
        )
        assert exit_code == 64, f"Expected exit code 64 for invalid argument, got {exit_code}"
    
    def test_asset_count_consistency(self, sample_assets, image_assets, video_assets):
        """Test that type-specific counts match total"""
        if sample_assets:
            total_images = count_assets_by_type(sample_assets, 'image')
            total_videos = count_assets_by_type(sample_assets, 'video')
            
            assert len(image_assets) == total_images, f"Image count mismatch: {len(image_assets)} vs {total_images}"
            assert len(video_assets) == total_videos, f"Video count mismatch: {len(video_assets)} vs {total_videos}"
            assert len(sample_assets) == total_images + total_videos, "Total count mismatch"

class TestExportAsset:
    """Test export-asset command functionality"""
    
    def test_export_image_asset(self, image_assets, temp_export_dir):
        """Test exporting a valid image asset"""
        if not image_assets:
            pytest.skip("No image assets available for testing")
        
        asset_id = image_assets[0]['id']
        result = run_swift_command(['export-asset', asset_id, temp_export_dir])
        
        validate_export_schema(result)
        
        # Verify file actually exists and has content
        exported_file = Path(result['file_path'])
        assert exported_file.exists(), f"Exported file missing: {exported_file}"
        assert exported_file.stat().st_size > 0, f"Exported file is empty: {exported_file}"
        
        # Verify metadata consistency
        metadata = result['metadata']
        assert metadata['media_type'] == 'image', f"Expected image media type, got {metadata['media_type']}"
        
        print(f"Successfully exported image: {exported_file.name} ({metadata['file_size']} bytes)")
    
    def test_export_video_asset(self, video_assets, temp_export_dir):
        """Test exporting a valid video asset"""
        if not video_assets:
            pytest.skip("No video assets available for testing")
        
        asset_id = video_assets[0]['id']
        result = run_swift_command(['export-asset', asset_id, temp_export_dir])
        
        validate_export_schema(result)
        
        # Verify file exists and has content
        exported_file = Path(result['file_path'])
        assert exported_file.exists(), f"Exported video file missing: {exported_file}"
        assert exported_file.stat().st_size > 0, f"Exported video file is empty: {exported_file}"
        
        # Verify video-specific metadata
        metadata = result['metadata']
        assert metadata['media_type'] == 'video', f"Expected video media type, got {metadata['media_type']}"
        
        print(f"Successfully exported video: {exported_file.name} ({metadata['file_size']} bytes)")
    
    def test_export_to_nonexistent_directory(self, image_assets):
        """Test export to non-existent directory"""
        if not image_assets:
            pytest.skip("No image assets available for testing")
        
        asset_id = image_assets[0]['id']
        exit_code, stderr = run_swift_command(
            ['export-asset', asset_id, '/nonexistent/directory'],
            expect_success=False
        )
        assert exit_code == 4, f"Expected exit code 4 for export failure, got {exit_code}"
    
    def test_filename_generation(self, image_assets, temp_export_dir):
        """Test that exported filenames are properly generated"""
        if not image_assets:
            pytest.skip("No image assets available for testing")
        
        asset = image_assets[0]
        result = run_swift_command(['export-asset', asset['id'], temp_export_dir])
        
        exported_file = Path(result['file_path'])
        
        # Verify filename format: asset_{sanitized_id}.{extension}
        assert exported_file.name.startswith('asset_'), f"Filename should start with 'asset_': {exported_file.name}"
        assert '.' in exported_file.name, f"Filename should have extension: {exported_file.name}"
        
        # Verify sanitized asset ID in filename
        sanitized_id = asset['id'].replace('/', '_')
        assert sanitized_id in exported_file.name, f"Asset ID not found in filename: {exported_file.name}"

class TestErrorHandling:
    """Test error conditions and edge cases"""
    
    def test_invalid_asset_id(self, temp_export_dir):
        """Test error handling for non-existent asset"""
        exit_code, stderr = run_swift_command(
            ['export-asset', 'INVALID_ASSET_ID', temp_export_dir],
            expect_success=False
        )
        assert exit_code == 3, f"Expected exit code 3 for asset not found, got {exit_code}"
    
    def test_missing_arguments(self):
        """Test handling of missing required arguments"""
        # Missing asset ID and output directory
        exit_code, stderr = run_swift_command(['export-asset'], expect_success=False)
        assert exit_code == 64, f"Expected exit code 64 for missing args, got {exit_code}"
        
        # Missing output directory
        exit_code, stderr = run_swift_command(['export-asset', 'SOME_ID'], expect_success=False)
        assert exit_code == 64, f"Expected exit code 64 for missing output dir, got {exit_code}"
    
    def test_unknown_command(self):
        """Test handling of unknown commands"""
        exit_code, stderr = run_swift_command(['unknown-command'], expect_success=False)
        assert exit_code == 64, f"Expected exit code 64 for unknown command, got {exit_code}"
    
    def test_help_commands(self):
        """Test help commands work correctly"""
        # Help commands don't return JSON, they return text
        # We should test them separately without expecting JSON
        import subprocess
        
        # Main help
        result = subprocess.run(['.lib/photo-exporter', '--help'], capture_output=True, text=True)
        assert result.returncode == 0, f"Help command failed with exit code {result.returncode}"
        assert 'OVERVIEW' in result.stdout, "Help should contain overview"
        
        # Subcommand help
        result = subprocess.run(['.lib/photo-exporter', 'list-assets', '--help'], capture_output=True, text=True)
        assert result.returncode == 0, f"list-assets help failed with exit code {result.returncode}"
        
        result = subprocess.run(['.lib/photo-exporter', 'export-asset', '--help'], capture_output=True, text=True)
        assert result.returncode == 0, f"export-asset help failed with exit code {result.returncode}"

class TestLivePhotos:
    """Test Live Photos detection and handling"""
    
    def test_live_photos_detection(self, live_photo_assets):
        """Test Live Photos are properly flagged in list-assets"""
        if not live_photo_assets:
            pytest.skip("No Live Photos available for testing")
        
        print(f"Found {len(live_photo_assets)} Live Photos")
        
        # Verify Live Photo assets have proper metadata
        for live_photo in live_photo_assets:
            assert live_photo['type'] == 'image', f"Live Photo should be image type, got {live_photo['type']}"
            assert live_photo['is_live_photo'] is True, f"Expected is_live_photo=True for {live_photo['id']}"
    
    def test_live_photo_export(self, live_photo_assets, temp_export_dir):
        """Test exporting Live Photo returns only image component"""
        if not live_photo_assets:
            pytest.skip("No Live Photos available for testing")
        
        asset_id = live_photo_assets[0]['id']
        result = run_swift_command(['export-asset', asset_id, temp_export_dir])
        
        validate_export_schema(result)
        metadata = result['metadata']
        
        # Verify Live Photo handling
        assert metadata['is_live_photo'] is True, f"Expected is_live_photo=True in export metadata"
        assert metadata['live_photo_video_complement'] is None, f"Video complement should be None (not exported)"
        
        # Verify only image file exported (not video)
        exported_file = Path(result['file_path'])
        assert exported_file.exists(), f"Live Photo image not exported: {exported_file}"
        
        # Check file extension is image format
        image_extensions = ['.heic', '.jpg', '.jpeg', '.png']
        assert any(exported_file.suffix.lower().endswith(ext) for ext in image_extensions), \
            f"Live Photo export should be image format, got: {exported_file.suffix}"
        
        print(f"Successfully exported Live Photo (image only): {exported_file.name}")
    
    def test_regular_vs_live_photos(self, regular_photo_assets, live_photo_assets):
        """Test distinction between regular photos and Live Photos"""
        if regular_photo_assets:
            for asset in regular_photo_assets[:3]:  # Test first 3
                assert asset['is_live_photo'] is False, f"Regular photo incorrectly marked as Live Photo: {asset['id']}"
        
        if live_photo_assets:
            for asset in live_photo_assets:
                assert asset['is_live_photo'] is True, f"Live Photo not properly detected: {asset['id']}"
        
        print(f"Regular photos: {len(regular_photo_assets)}, Live Photos: {len(live_photo_assets)}")

class TestPerformance:
    """Test performance characteristics"""
    
    def test_list_assets_performance(self):
        """Test list-assets performance with timing"""
        result, duration = measure_performance(run_swift_command, ['list-assets'])
        
        # Should complete within reasonable time (adjust based on library size)
        assert duration < 10.0, f"list-assets took too long: {duration:.2f} seconds"
        print(f"Listed {len(result)} assets in {duration:.2f} seconds")
    
    def test_export_performance(self, image_assets, temp_export_dir):
        """Test single asset export performance"""
        if not image_assets:
            pytest.skip("No image assets available for testing")
        
        asset_id = image_assets[0]['id']
        
        result, duration = measure_performance(
            run_swift_command, 
            ['export-asset', asset_id, temp_export_dir]
        )
        
        assert duration < 30.0, f"Export took too long: {duration:.2f} seconds"
        
        file_size_mb = result['metadata']['file_size'] / (1024 * 1024)
        print(f"Exported {file_size_mb:.2f} MB in {duration:.2f} seconds")
    
    def test_multiple_exports_performance(self, small_asset_list, temp_export_dir):
        """Test performance of multiple exports"""
        if len(small_asset_list) < 2:
            pytest.skip("Need at least 2 assets for batch performance test")
        
        start_time = __import__('time').time()
        successful_exports = 0
        
        for asset in small_asset_list:
            try:
                result = run_swift_command(['export-asset', asset['id'], temp_export_dir])
                successful_exports += 1
            except Exception as e:
                print(f"Failed to export {asset['id']}: {e}")
        
        total_duration = __import__('time').time() - start_time
        avg_duration = total_duration / successful_exports if successful_exports > 0 else 0
        
        print(f"Exported {successful_exports}/{len(small_asset_list)} assets in {total_duration:.2f}s (avg: {avg_duration:.2f}s per asset)")

class TestDataIntegrity:
    """Test data consistency and integrity"""
    
    def test_asset_id_uniqueness(self, sample_assets):
        """Test that all asset IDs are unique"""
        if not sample_assets:
            pytest.skip("No assets available for uniqueness test")
        
        asset_ids = [asset['id'] for asset in sample_assets]
        unique_ids = set(asset_ids)
        
        assert len(asset_ids) == len(unique_ids), f"Found duplicate asset IDs: {len(asset_ids)} total, {len(unique_ids)} unique"
    
    def test_creation_dates_format(self, sample_assets):
        """Test that creation dates are properly formatted"""
        if not sample_assets:
            pytest.skip("No assets available for date format test")
        
        for asset in sample_assets[:10]:  # Test first 10 assets
            date = asset['creation_date']
            assert 'T' in date, f"Invalid date format (missing T): {date}"
            assert date.endswith('Z'), f"Date should end with Z: {date}"
            assert len(date) >= 20, f"Date too short: {date}"
    
    def test_metadata_consistency(self, image_assets, temp_export_dir):
        """Test metadata consistency between list and export"""
        if not image_assets:
            pytest.skip("No image assets available for metadata test")
        
        # Get asset from list
        list_asset = image_assets[0]
        
        # Export same asset
        export_result = run_swift_command(['export-asset', list_asset['id'], temp_export_dir])
        export_metadata = export_result['metadata']
        
        # Compare consistent fields
        assert export_metadata['creation_date'] == list_asset['creation_date'], \
            f"Creation date mismatch: list={list_asset['creation_date']}, export={export_metadata['creation_date']}"
        
        assert export_metadata['is_live_photo'] == list_asset['is_live_photo'], \
            f"Live Photo status mismatch: list={list_asset['is_live_photo']}, export={export_metadata['is_live_photo']}"
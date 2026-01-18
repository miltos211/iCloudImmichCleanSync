import pytest
import sys
import os
sys.path.append(os.path.dirname(os.path.abspath(__file__)))
from swift_test_helpers import run_swift_command, create_temp_export_dir, cleanup_temp_dir

@pytest.fixture
def sample_assets():
    """Get sample assets for testing"""
    return run_swift_command(['list-assets', '--type', 'all'])

@pytest.fixture  
def image_assets():
    """Get only image assets"""
    return run_swift_command(['list-assets', '--type', 'image'])

@pytest.fixture
def video_assets():
    """Get only video assets"""
    return run_swift_command(['list-assets', '--type', 'video'])

@pytest.fixture
def image_assets_no_screenshots():
    """Get image assets excluding screenshots"""
    return run_swift_command(['list-assets', '--type', 'image', '--no-screenshots'])

@pytest.fixture
def screenshot_assets():
    """Get only screenshot assets"""
    return run_swift_command(['list-assets', '--screenshots-only'])

@pytest.fixture
def temp_export_dir():
    """Provide temporary export directory"""
    temp_dir = create_temp_export_dir()
    yield temp_dir
    cleanup_temp_dir(temp_dir)

@pytest.fixture
def small_asset_list():
    """Get a small list of assets for performance tests"""
    all_assets = run_swift_command(['list-assets', '--type', 'image'])
    return all_assets[:5]  # Return first 5 assets only

@pytest.fixture
def live_photo_assets(image_assets):
    """Get Live Photo assets if any exist"""
    return [asset for asset in image_assets if asset['is_live_photo']]

@pytest.fixture 
def regular_photo_assets(image_assets):
    """Get regular photo assets (non-Live Photos)"""
    return [asset for asset in image_assets if not asset['is_live_photo']]
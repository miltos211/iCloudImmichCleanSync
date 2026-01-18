import sys
import os
from pathlib import Path

# Add tests directory to Python path
tests_dir = Path(__file__).parent / "tests"
sys.path.insert(0, str(tests_dir))
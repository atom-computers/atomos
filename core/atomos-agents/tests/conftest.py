"""
Ensures the src/ directory is on sys.path for all test modules,
matching the PYTHONPATH=src convention used in run_integration.sh.
"""
import sys
from pathlib import Path

_SRC = str(Path(__file__).parent.parent / "src")
if _SRC not in sys.path:
    sys.path.insert(0, _SRC)

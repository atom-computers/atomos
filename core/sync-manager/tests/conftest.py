import os
import sys
from unittest.mock import patch

# Setup python path
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

# Mock cocoindex init globally BEFORE main is imported in tests
patcher = patch("cocoindex.init")
patcher.start()

# We also need to patch out other fast-fail operations like models loading
# if it helps, but init is sufficient for collection to pass.
import cocoindex

def mock_function(func=None, *args, **kwargs):
    if func:
        return func
    return lambda f: f

cocoindex.function = mock_function

def mock_flow_def(*args, **kwargs):
    return lambda f: f

cocoindex.flow_def = mock_flow_def

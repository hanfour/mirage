import sys
from pathlib import Path


HARNESS_DIR = str(Path(__file__).resolve().parents[1])
if HARNESS_DIR not in sys.path:
    sys.path.insert(0, HARNESS_DIR)

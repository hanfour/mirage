"""Load the SDK and AVD specification shared with the Mirage app."""
from __future__ import annotations

import json
from pathlib import Path


SPEC_PATH = Path(__file__).resolve().parents[3] / "app" / "Sources" / "MirageCore" / "Resources" / "sdk-spec.json"


def load_spec() -> dict:
    with SPEC_PATH.open(encoding="utf-8") as handle:
        return json.load(handle)

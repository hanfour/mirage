"""Two AVDs share this base config; both the app and provisioner read sdk-spec.json."""
from __future__ import annotations

from lib.sdk_spec import load_spec


BASE: dict[str, str] = load_spec()["configBase"]

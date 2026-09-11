"""Best-effort emulator discovery and token metadata for plaintext gRPC."""
from collections import namedtuple
from dataclasses import dataclass, field
import errno
import os
from pathlib import Path
import re

import grpc


@dataclass(frozen=True)
class DiscoveryFile:
    name: str
    text: str = field(repr=False)
    modified: float


def parse_ini(text: str) -> dict[str, str]:
    """Discovery values can contain quotes, spaces and additional '=' signs."""
    fields = {}
    for line in text.splitlines():
        key, separator, value = line.partition("=")
        if separator:
            fields[key.strip()] = value.strip()
    return fields


def select_token(files, port: int, is_alive) -> str | None:
    """Pure selection when supplied an in-memory liveness predicate."""
    try:
        candidates = []
        for entry in files:
            match = re.fullmatch(r"pid_([0-9]+)\.ini", entry.name)
            if not match or int(match[1]) <= 0:
                continue
            fields = parse_ini(entry.text)
            if fields.get("grpc.port") != str(port):
                continue
            if is_alive(int(match[1])):
                candidates.append((entry.modified, entry.name, fields))
        if not candidates:
            return None
        # Select the instance first; a newer insecure instance must not use an old token.
        return max(candidates, key=lambda item: item[:2])[2].get("grpc.token") or None
    except Exception:
        return None


def pid_is_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError as error:
        return error.errno == errno.EPERM
    except Exception:
        return False


def read_discovery_files(directory: Path) -> list[DiscoveryFile]:
    return [DiscoveryFile(path.name, path.read_text(encoding="utf-8"), path.stat().st_mtime_ns)
            for path in directory.iterdir() if re.fullmatch(r"pid_[0-9]+\.ini", path.name)]


def discover_token(port: int, running_dir=None, is_alive=pid_is_alive,
                   read_files=read_discovery_files) -> str | None:
    """All discovery errors fall back to unauthenticated calls, without logging secrets."""
    try:
        directory = (Path(running_dir) if running_dir is not None else
                     Path.home() / "Library/Caches/TemporaryItems/avd/running")
        return select_token(read_files(directory), port, is_alive)
    except Exception:
        return None


def auth_metadata(port: int, **discovery_options) -> list[tuple[str, str]]:
    token = discover_token(port, **discovery_options)
    return [("authorization", f"Bearer {token}")] if token else []


class _CallDetails(namedtuple("_CallDetails", (
        "method", "timeout", "metadata", "credentials", "wait_for_ready", "compression")),
        grpc.ClientCallDetails):
    pass


class AuthInterceptor(grpc.UnaryUnaryClientInterceptor, grpc.UnaryStreamClientInterceptor,
                      grpc.StreamUnaryClientInterceptor, grpc.StreamStreamClientInterceptor):
    def __init__(self, metadata):
        self._metadata = tuple(metadata)

    def _intercept(self, continuation, details, request):
        enriched = _CallDetails(
            details.method, details.timeout,
            list(details.metadata or ()) + list(self._metadata),
            details.credentials, getattr(details, "wait_for_ready", None),
            getattr(details, "compression", None))
        return continuation(enriched, request)

    intercept_unary_unary = _intercept
    intercept_unary_stream = _intercept
    intercept_stream_unary = _intercept
    intercept_stream_stream = _intercept


def open_channel(port: int, options=None):
    # Resolve on every new channel so reconnects pick up the current boot's token.
    metadata = auth_metadata(port)
    return grpc.intercept_channel(
        grpc.insecure_channel(f"localhost:{port}", options=options), AuthInterceptor(metadata))

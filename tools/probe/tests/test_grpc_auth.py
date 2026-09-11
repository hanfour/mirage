"""Discovery and interception tests use only fabricated credentials and injected I/O."""
import errno
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock

import grpc
import pytest

from lib import grpc_auth as auth


SAMPLE = '''emulator.build=15917651
avd.id=mirage-game
emulator.version=37.1.11.0
port.serial=5554
port.adb=5555
avd.name=mirage-game
avd.dir=/example/.android/avd/mirage-game.avd
cmdline="/example/qemu-system-aarch64" "-avd" "mirage-game" "-no-snapshot" "-port" "5554" "-grpc" "8554" "-grpc-use-token"
grpc.token=fake-token=only
launcher.dir=/example/emulator
grpc.allowlist=/example/emulator/lib/emulator_access.json
grpc.port=8554
'''


def entry(pid=123, text=SAMPLE, modified=1):
    return auth.DiscoveryFile(f"pid_{pid}.ini", text, modified)


def test_parse_real_format_with_fake_token():
    fields = auth.parse_ini(SAMPLE)
    assert fields['grpc.port'] == '8554'
    assert fields['grpc.token'] == 'fake-token=only'
    assert fields['cmdline'] == SAMPLE.split('cmdline=', 1)[1].splitlines()[0]
    assert auth.parse_ini('cmdline="arg=a b"\nignored\n') == {'cmdline': '"arg=a b"'}
    assert auth.select_token([entry()], 8554, lambda _: True) == 'fake-token=only'


@pytest.mark.parametrize('text', [SAMPLE.replace('grpc.token=fake-token=only\n', ''),
                                  SAMPLE.replace('fake-token=only', ''),
                                  SAMPLE.replace('fake-token=only', '  ')])
def test_absent_or_empty_token(text):
    assert auth.select_token([entry(text=text)], 8554, lambda _: True) is None


def test_wrong_port_does_not_check_liveness():
    def unexpected(_):
        pytest.fail('wrong port must be filtered before liveness')
    assert auth.select_token([entry()], 8556, unexpected) is None


def test_dead_pid():
    assert auth.select_token([entry()], 8554, lambda _: False) is None


def test_newest_live_matching_instance_wins():
    files = [entry(1), entry(2, SAMPLE.replace('fake-token=only', 'fake-new'), 2),
             entry(3, SAMPLE.replace('fake-token=only', 'fake-dead'), 3),
             entry(4, SAMPLE.replace('8554', '8556'), 4)]
    for order in (files, list(reversed(files))):
        assert auth.select_token(order, 8554, lambda pid: pid != 3) == 'fake-new'


def test_newest_insecure_instance_does_not_reuse_old_token():
    files = [entry(), entry(124, 'grpc.port=8554', 2)]
    assert auth.select_token(files, 8554, lambda _: True) is None


@pytest.mark.parametrize('name', ['pid_0.ini', 'pid_-1.ini', 'pid_bad.ini', 'other.ini'])
def test_invalid_filename(name):
    assert auth.select_token([auth.DiscoveryFile(name, SAMPLE, 1)],
                             8554, lambda _: True) is None


@pytest.mark.parametrize('error', [FileNotFoundError, PermissionError, UnicodeError, RuntimeError])
def test_discovery_errors_return_no_metadata(error):
    def read_files(directory):
        assert directory == Path('/fake/running')
        raise error('fabricated discovery failure')
    assert auth.auth_metadata(8554, running_dir='/fake/running',
                              read_files=read_files, is_alive=lambda _: True) == []


def test_io_entry_is_injectable_and_refreshes():
    files = [entry()]
    def read_files(directory):
        assert directory == Path('/fake/running')
        return files
    options = dict(running_dir='/fake/running', read_files=read_files, is_alive=lambda _: True)
    assert auth.auth_metadata(8554, **options) == [('authorization', 'Bearer fake-token=only')]
    files[:] = [entry(text=SAMPLE.replace('fake-token=only', 'fake-reboot'))]
    assert auth.discover_token(8554, **options) == 'fake-reboot'


def test_liveness_error_returns_no_token():
    def broken(_):
        raise RuntimeError('fabricated liveness failure')
    assert auth.select_token([entry()], 8554, broken) is None


@pytest.mark.parametrize(('error', 'expected'), [(None, True), (errno.EPERM, True),
                                                (errno.ESRCH, False), (errno.EINVAL, False)])
def test_kill_zero_semantics(monkeypatch, error, expected):
    def kill(pid, signal):
        assert (pid, signal) == (123, 0)
        if error:
            raise OSError(error, 'fabricated process check')
    monkeypatch.setattr(auth.os, 'kill', kill)
    assert auth.pid_is_alive(123) is expected


def test_reader_uses_first_equals_and_mtime_without_real_files():
    path = MagicMock()
    path.name = 'pid_123.ini'
    path.read_text.return_value = SAMPLE
    path.stat.return_value.st_mtime_ns = 42
    directory = MagicMock()
    directory.iterdir.return_value = [path]
    files = auth.read_discovery_files(directory)
    assert files[0].modified == 42
    assert auth.select_token(files, 8554, lambda _: True) == 'fake-token=only'


@pytest.mark.parametrize('kind', ['unary_unary', 'unary_stream', 'stream_unary', 'stream_stream'])
@pytest.mark.parametrize('metadata', [None, [('caller-key', 'caller-value')]])
def test_interceptor_preserves_call_details(kind, metadata):
    interceptor = auth.AuthInterceptor([('authorization', 'Bearer fake-interceptor')])
    details = SimpleNamespace(method='/fake/Method', timeout=12, metadata=metadata,
                              credentials=object(), wait_for_ready=True,
                              compression=grpc.Compression.Gzip)
    request = iter([b'request']) if kind.startswith('stream') else b'request'
    result = object()
    def continuation(enriched, received):
        assert isinstance(enriched, grpc.ClientCallDetails)
        assert enriched.metadata == list(metadata or []) + [('authorization', 'Bearer fake-interceptor')]
        for field in ('method', 'timeout', 'credentials', 'wait_for_ready', 'compression'):
            assert getattr(enriched, field) == getattr(details, field)
        assert received is request
        return result
    assert getattr(interceptor, f'intercept_{kind}')(continuation, details, request) is result
    assert details.metadata == metadata


def test_open_channel_context_manager_options_and_fresh_discovery(monkeypatch):
    metadata = MagicMock(side_effect=[[], [('authorization', 'Bearer fake-reboot')]])
    monkeypatch.setattr(auth, 'auth_metadata', metadata)
    underlying = MagicMock(spec=grpc.Channel)
    create = MagicMock(return_value=underlying)
    monkeypatch.setattr(auth.grpc, 'insecure_channel', create)
    options = [('grpc.max_receive_message_length', 1024)]
    for _ in range(2):
        with auth.open_channel(8554, options=options) as channel:
            assert isinstance(channel, grpc.Channel)
    assert metadata.call_count == 2
    create.assert_called_with('localhost:8554', options=options)
    assert underlying.close.call_count == 2

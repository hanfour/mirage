"""使用本機 HTTP 與暫存目錄驗證 I/O，不下載套件或啟動模擬器。"""
import hashlib
import http.server
import os
from pathlib import Path
import tempfile
import threading
import urllib.request
import unittest
from unittest.mock import patch

import fetch
import provision
from lib import config_ini, report, versions
from lib.avdspec import SPECS
from tests.test_fetch import _make_zip

BODY = '已知內容\n'.encode()


class LocalHttpTests(unittest.TestCase):
    def setUp(self):
        self.routes = {"/data": BODY}
        routes = self.routes

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path == "/broken":
                    self.send_response(200)
                    self.send_header("Transfer-Encoding", "chunked")
                    self.end_headers()
                    self.wfile.write(b"4\r\npart\r\n8\r\nx")
                    self.close_connection = True
                    return
                if self.path not in routes:
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header("Content-Length", str(len(routes[self.path])))
                self.end_headers()
                self.wfile.write(routes[self.path])

            def log_message(self, *args):
                pass

        # HTTPServer 預設反查名稱；測試只需固定的本機位址。
        with patch("http.server.socket.getfqdn", return_value="localhost"):
            self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.addCleanup(self.server.server_close)
        self.thread = threading.Thread(target=self.server.serve_forever)
        self.thread.start()
        self.addCleanup(self.thread.join)
        self.addCleanup(self.server.shutdown)
        self.base = f"http://127.0.0.1:{self.server.server_port}"
        # 不讓使用者的代理伺服器設定把本機請求轉送出去。
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        self.opener_patch = patch('fetch.urllib.request.urlopen', opener.open)
        self.opener_patch.start()
        self.addCleanup(self.opener_patch.stop)

    def test_download_publishes_only_verified_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            dest = os.path.join(tmp, "data")
            real_replace = os.replace

            def checked_replace(src, dst):
                self.assertEqual((src, dst), (dest + ".part", dest))
                self.assertEqual(Path(src).read_bytes(), BODY)
                self.assertFalse(Path(dst).exists())
                real_replace(src, dst)

            with patch("fetch.os.replace", side_effect=checked_replace) as replace:
                fetch.download(self.base + "/data", dest, hashlib.sha1(BODY).hexdigest(), len(BODY))
            replace.assert_called_once()
            self.assertEqual(Path(dest).read_bytes(), BODY)
            self.assertEqual(os.listdir(tmp), ["data"])

    def test_download_interrupted_removes_part(self):
        with tempfile.TemporaryDirectory() as tmp:
            dest = os.path.join(tmp, "data")
            with self.assertRaises(fetch.FetchError):
                fetch.download(self.base + "/broken", dest, hashlib.sha1(BODY).hexdigest(), len(BODY))
            self.assertEqual(os.listdir(tmp), [])

    def test_download_size_mismatch_rejects_before_replace(self):
        with tempfile.TemporaryDirectory() as tmp:
            dest = os.path.join(tmp, "data")
            Path(dest).write_bytes(b"previous")
            with patch("fetch.os.replace", wraps=os.replace) as replace:
                with self.assertRaisesRegex(fetch.FetchError, "大小"):
                    fetch.download(self.base + "/data", dest, hashlib.sha1(BODY).hexdigest(), len(BODY) + 1)
            replace.assert_not_called()
            self.assertEqual(Path(dest).read_bytes(), b"previous")
            self.assertEqual(os.listdir(tmp), ["data"])

    def test_download_checksum_mismatch_never_publishes(self):
        with tempfile.TemporaryDirectory() as tmp:
            with patch("fetch.os.replace", wraps=os.replace) as replace:
                with self.assertRaisesRegex(fetch.FetchError, "sha1"):
                    fetch.download(self.base + "/data", os.path.join(tmp, "data"), "0" * 40, len(BODY))
            replace.assert_not_called()
            self.assertEqual(os.listdir(tmp), [])

    def test_fetch_text_decodes_utf8(self):
        self.assertEqual(fetch.fetch_text(self.base + "/data"), BODY.decode())

    def test_fetch_text_non_200(self):
        with self.assertRaisesRegex(fetch.FetchError, "HTTP 404"):
            fetch.fetch_text(self.base + "/missing")

    def test_resolve_fetches_parses_and_checks_pins(self):
        for key in versions.MANIFESTS:
            packages = []
            for pin in versions.PINS:
                if pin.manifest_key != key:
                    continue
                revision = ''.join(f'<{k}>{v}</{k}>' for k, v in
                                   zip(('major', 'minor', 'micro'), pin.revision.split('.')))
                packages.append(f'''<remotePackage path="{pin.path}">
                    <revision>{revision}</revision><channelRef ref="channel-0"/>
                    <archives><archive><host-os>macosx</host-os><host-arch>aarch64</host-arch>
                    <complete><size>{pin.size}</size><checksum type="sha1">{pin.sha1}</checksum>
                    <url>{key}.zip</url></complete></archive></archives></remotePackage>''')
            self.routes['/' + key] = ('<repository><channel id="channel-0">stable</channel>'
                                      + ''.join(packages) + '</repository>').encode()
        with patch.object(versions, 'MANIFESTS', {k: self.base + '/' + k for k in versions.MANIFESTS}), \
             patch.object(versions, 'MANIFEST_BASES', {k: self.base + '/' for k in versions.MANIFESTS}), \
             patch('platform.system', return_value='Darwin'), \
             patch('platform.machine', return_value='arm64'):
            resolved = provision._resolve()
            self.assertEqual([pin for pin, ref in resolved], list(versions.PINS))
            for pin, ref in resolved:
                self.assertEqual(ref.url, self.base + '/' + pin.manifest_key + '.zip')
            self.routes['/repo'] = self.routes['/repo'].replace(versions.PINS[0].sha1.encode(), b'0' * 40)
            with self.assertRaises(versions.PinDriftError):
                provision._resolve()


class AvdReadOnlyTests(unittest.TestCase):
    def test_missing_avds_are_reported_without_creating_home(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = os.path.join(tmp, "missing")
            rows = provision._avd_rows(home, False, "/opt/sdk")
            self.assertFalse(os.path.exists(home))
            self.assertEqual([row.label for row in rows], [s.name for s in SPECS])
            self.assertEqual(report.exit_code(rows), 1)
            self.assertTrue(all(row.detail == "缺少（需 --apply 才會建立）" for row in rows))

    def test_existing_config_and_missing_pointer_remain_unchanged(self):
        with tempfile.TemporaryDirectory() as tmp:
            spec = SPECS[0]
            directory = Path(tmp, spec.name + '.avd')
            directory.mkdir()
            path = directory / 'config.ini'
            text = config_ini.render_config(spec, '/opt/sdk') + 'aaa.extra = value\n'
            path.write_text(text)
            rows = provision._avd_rows(tmp, False, '/opt/sdk')
            self.assertEqual(path.read_text(), text)
            self.assertEqual(sorted(p.name for p in Path(tmp).iterdir()), [directory.name])
            self.assertIn('aaa.extra 應移除', rows[0].detail)
            self.assertNotIn('None', report.format_report('AVD', rows))


class OrphanBackupTests(unittest.TestCase):
    def test_orphan_removed_when_install_directory_is_absent(self):
        with tempfile.TemporaryDirectory() as tmp:
            install = os.path.join(tmp, 'emulator')
            orphan = Path(install + '.provision-old')
            orphan.mkdir()
            (orphan / 'large-old-image').write_bytes(b'old')
            archive = _make_zip(tmp, 'pkg', {'new': 'new'})
            fetch.extract_into(archive, install)
            self.assertFalse(orphan.exists())
            self.assertEqual(Path(install, 'new').read_text(), 'new')
            self.assertFalse(any(p.name.startswith('.provision-') for p in Path(tmp).iterdir()))


class ReportWidthTests(unittest.TestCase):
    def test_width_follows_longest_actual_label(self):
        rows = [report.Row('short', True, 'detail', ''), report.Row('x' * 83, True, 'detail', '')]
        lines = report.format_report('title', rows).splitlines()[1:]
        self.assertEqual(lines[0].index('detail'), lines[1].index('detail'))
        self.assertEqual(report.format_report('empty', []), 'empty\n')

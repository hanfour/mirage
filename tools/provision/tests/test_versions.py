import unittest

from lib.manifest import PackageRef
from lib.versions import MANIFESTS, PINS, PinDriftError, resolve_pins, validate_pinned_urls


def _ref(pin, **overrides):
    """由 pin 造一個「完全相符」的 PackageRef，再讓各測試改壞其中一欄。"""
    fields = dict(
        path=pin.path,
        revision=pin.revision,
        channel=pin.channel,
        url=pin.url,
        sha1=pin.sha1,
        size=pin.size,
    )
    fields.update(overrides)
    return PackageRef(**fields)


def _all_matching(**overrides_by_path):
    refs = {key: [] for key in MANIFESTS}
    for pin in PINS:
        refs[pin.manifest_key].append(_ref(pin, **overrides_by_path.get(pin.path, {})))
    return refs


class PinTableTests(unittest.TestCase):
    def test_every_pin_names_a_known_manifest(self):
        for pin in PINS:
            self.assertIn(pin.manifest_key, MANIFESTS)

    def test_pins_cover_the_four_packages(self):
        self.assertEqual(
            sorted(pin.path for pin in PINS),
            [
                "emulator",
                "platform-tools",
                "system-images;android-35;default;arm64-v8a",
                "system-images;android-35;google_apis_playstore;arm64-v8a",
            ],
        )

    def test_every_pin_has_a_forty_char_sha1(self):
        for pin in PINS:
            self.assertEqual(len(pin.sha1), 40, pin.path)

    def test_every_pin_has_a_download_url(self):
        for pin in PINS:
            self.assertTrue(pin.url.startswith("https://"), pin.path)


class ResolveTests(unittest.TestCase):
    def test_all_matching_resolves(self):
        resolved = resolve_pins(_all_matching())
        self.assertEqual(len(resolved), len(PINS))

    def test_newer_revision_on_manifest_is_fatal(self):
        """Google bump 之後 manifest 只剩新版。默默採用它會讓同一份 commit
        在不同日子跑出不同環境——D33 要消滅的正是這件事。"""
        refs = _all_matching(emulator={"revision": "37.2.13"})
        with self.assertRaises(PinDriftError) as caught:
            resolve_pins(refs)
        message = str(caught.exception)
        self.assertIn("37.2.12", message)
        self.assertIn("37.2.13", message)

    def test_same_revision_different_sha1_is_fatal(self):
        """版本號相同但 sha1 變了，代表上游重新打包過。這比 revision 改變
        更危險，因為它不會反映在任何版本號上。"""
        refs = _all_matching(**{"platform-tools": {"sha1": "0" * 40}})
        with self.assertRaises(PinDriftError):
            resolve_pins(refs)

    def test_same_revision_different_size_is_fatal(self):
        refs = _all_matching(emulator={"size": PINS[0].size + 1})
        with self.assertRaises(PinDriftError):
            resolve_pins(refs)

    def test_manifest_url_drift_is_fatal(self):
        resolved = resolve_pins(_all_matching(emulator={"url": "https://example.invalid/new.zip"}))
        with self.assertRaises(PinDriftError) as caught:
            validate_pinned_urls(resolved)
        self.assertIn("url", str(caught.exception))

    def test_missing_package_is_fatal(self):
        refs = _all_matching()
        refs["repo"] = [r for r in refs["repo"] if r.path != "emulator"]
        with self.assertRaises(PinDriftError) as caught:
            resolve_pins(refs)
        self.assertIn("emulator", str(caught.exception))

    def test_error_message_says_it_needs_a_commit(self):
        """訊息要讓讀的人知道這不是「重跑一次就會好」的錯誤，
        而是一個需要有人做決定並留下 commit 的事件。"""
        refs = _all_matching(emulator={"revision": "37.2.13"})
        with self.assertRaises(PinDriftError) as caught:
            resolve_pins(refs)
        self.assertIn("sdk-spec.json", str(caught.exception))


if __name__ == "__main__":
    unittest.main()

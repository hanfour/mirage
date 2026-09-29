import unittest

from lib import versions
from lib.avdspec import SPECS
from lib.config_base import BASE
from lib.sdk_spec import load_spec


class SharedSdkSpecTests(unittest.TestCase):
    def test_python_views_match_shared_spec(self):
        spec = load_spec()
        self.assertEqual(spec["androidTarget"], versions.ANDROID_TARGET)
        self.assertEqual(spec["configBase"], BASE)
        self.assertEqual(
            [
                (item["manifestKey"], item["path"], item["channel"], item["revision"],
                 item["sha1"], item["size"], item["installPath"], item["url"])
                for item in spec["packages"]
            ],
            [
                (pin.manifest_key, pin.path, pin.channel, pin.revision, pin.sha1,
                 pin.size, pin.install_path, pin.url)
                for pin in versions.PINS
            ],
        )
        self.assertEqual(
            [
                (item["name"], item["imageManifest"], item["playstore"], item["tagId"], item["tagDisplay"])
                for item in spec["avds"]
            ],
            [
                (avd.name, avd.image_manifest, avd.playstore, avd.tag_id, avd.tag_display)
                for avd in SPECS
            ],
        )


if __name__ == "__main__":
    unittest.main()

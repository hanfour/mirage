import pathlib
import unittest

from lib.avdspec import SPECS
from lib.config_ini import render_config, render_pointer_ini


REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
GOLDEN_DIR = REPO_ROOT / "app" / "Tests" / "MirageCoreTests" / "Fixtures" / "avd"
GAME = next(spec for spec in SPECS if spec.name == "mirage-game")


class AvdGoldenTests(unittest.TestCase):
    def test_game_config_matches_swift_golden(self):
        expected = (GOLDEN_DIR / "mirage-game.config.ini").read_text(encoding="utf-8")
        self.assertEqual(render_config(GAME, sdk_root="/tmp/mirage-sdk"), expected)

    def test_game_pointer_matches_swift_golden(self):
        expected = (GOLDEN_DIR / "mirage-game.pointer.ini").read_text(encoding="utf-8")
        self.assertEqual(render_pointer_ini(GAME, "/tmp/mirage-avd"), expected)


if __name__ == "__main__":
    unittest.main()

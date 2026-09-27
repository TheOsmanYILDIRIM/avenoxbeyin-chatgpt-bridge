"""ChatGPT Web bridge toggle: Jev-style opt-in state around an external Node adapter."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / "template/.claude/scripts/beyin_v3_chatgpt.py"


def load():
    spec = importlib.util.spec_from_file_location("beyin_v3_chatgpt_tested", MODULE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ChatGPTBridgeToggleTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.state = self.root / "state"
        self.bridge = self.root / "bridge"
        (self.bridge / "src").mkdir(parents=True)
        (self.bridge / "src/cli.mjs").write_text("// synthetic\n", encoding="utf-8")
        (self.bridge / "package.json").write_text("{}", encoding="utf-8")
        self.m = load()

    def test_default_is_off_without_touching_node(self):
        with patch.object(self.m, "_call", side_effect=AssertionError("must stay inert")):
            self.assertEqual(self.m.status(self.state),
                             {"mode": "off", "configured": False, "available": False, "running": False})
        self.assertFalse((self.state / "chatgpt.json").exists())

    def test_on_starts_external_bridge_and_persists_only_path_and_mode(self):
        with patch.object(self.m, "_call", return_value={"status": "started", "running": True, "pid": 123}):
            result = self.m.set_mode(self.state, "on", self.bridge)
        self.assertEqual(result["mode"], "on")
        self.assertTrue(result["running"])
        saved = json.loads((self.state / "chatgpt.json").read_text(encoding="utf-8"))
        self.assertEqual(set(saved), {"mode", "bridge_root"})
        self.assertEqual(saved["mode"], "on")
        self.assertEqual(Path(saved["bridge_root"]), self.bridge.resolve())

    def test_on_is_idempotent_through_bridge_start(self):
        with patch.object(self.m, "_call", return_value={"status": "already_running", "running": True, "pid": 123}) as call:
            self.m.set_mode(self.state, "on", self.bridge)
            again = self.m.set_mode(self.state, "on")
        self.assertTrue(again["running"])
        self.assertEqual(call.call_count, 2)

    def test_off_stops_worker_but_keeps_bridge_configuration(self):
        with patch.object(self.m, "_call", return_value={"status": "started", "running": True}):
            self.m.set_mode(self.state, "on", self.bridge)
        with patch.object(self.m, "_call", return_value={"status": "stopped", "running": False}) as call:
            result = self.m.set_mode(self.state, "off")
        self.assertEqual(result["mode"], "off")
        self.assertFalse(result["running"])
        self.assertEqual(call.call_args.args[1], "stop")
        saved = json.loads((self.state / "chatgpt.json").read_text(encoding="utf-8"))
        self.assertEqual(saved["mode"], "off")
        self.assertEqual(Path(saved["bridge_root"]), self.bridge.resolve())

    def test_config_is_fail_closed_and_never_accepts_secret_fields(self):
        self.state.mkdir()
        (self.state / "chatgpt.json").write_text(
            json.dumps({"mode": "on", "bridge_root": str(self.bridge.resolve()), "password": "NOPE"}),
            encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "chatgpt_config_invalid"):
            self.m.status(self.state)

    def test_status_sanitizes_bridge_failure(self):
        (self.state).mkdir()
        (self.state / "chatgpt.json").write_text(
            json.dumps({"mode": "on", "bridge_root": str(self.bridge.resolve())}), encoding="utf-8")
        with patch.object(self.m, "_call", side_effect=ValueError("chatgpt_bridge_command_failed")):
            result = self.m.status(self.state)
        self.assertEqual(result["error"], "chatgpt_bridge_command_failed")
        self.assertNotIn("stderr", result)


if __name__ == "__main__":
    unittest.main()

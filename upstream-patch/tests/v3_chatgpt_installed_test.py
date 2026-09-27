"""Installed-product contract for the optional ChatGPT Web bridge.

This file is intended to run after the proposal files are copied into an
avenoxai/avenoxbeyin checkout.
"""
import json
from pathlib import Path
import tempfile
import unittest

from v3_package_helpers import install, isolated_env, run_python


class ChatGPTInstalledIntegrationTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="v3-chatgpt-product-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.vault = self.base / "vault"
        self.vault.mkdir()
        self.state = self.base / "state"
        self.env = isolated_env(self.base / "home")

    def install(self):
        result = install(self.vault, self.state, self.env)
        self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8", errors="replace"))

    def cli(self, *args, payload=None):
        return run_python(self.vault / "beyin.py", args, self.vault, self.env, payload)

    def test_install_includes_controller_but_creates_no_chatgpt_state(self):
        self.install()
        self.assertTrue((self.vault / ".claude/scripts/beyin_v3_chatgpt.py").is_file())
        self.assertFalse((self.state / "chatgpt.json").exists())

        status = self.cli("chatgpt", "status")
        self.assertEqual(status.returncode, 0, status.stderr.decode("utf-8", errors="replace"))
        payload = json.loads(status.stdout)
        self.assertEqual(payload["mode"], "off")
        self.assertFalse(payload["running"])

        doctor = self.cli("doctor")
        self.assertEqual(doctor.returncode, 0, doctor.stderr.decode("utf-8", errors="replace"))
        report = json.loads(doctor.stdout)
        self.assertEqual(report["chatgpt_bridge"],
                         {"mode": "off", "configured": False, "available": False, "running": False})

    def test_receipt_accepts_chatgpt_without_adding_lifecycle_harness(self):
        self.install()
        note = self.vault / "notes/result.md"
        note.parent.mkdir(parents=True)
        note.write_text("Synthetic ChatGPT result.\n", encoding="utf-8")

        saved = self.cli("receipt", "--harness", "chatgpt", payload={
            "event_id": "chatgpt-product-receipt",
            "summary": "Synthetic ChatGPT bridge result.",
            "refs": ["notes/result.md"],
        })
        self.assertEqual(saved.returncode, 0, saved.stderr.decode("utf-8", errors="replace"))
        result = json.loads(saved.stdout)
        source = self.vault / result["source"]
        self.assertIn('"harness": "chatgpt"', source.read_text(encoding="utf-8"))

        doctor = json.loads(self.cli("doctor").stdout)
        self.assertNotIn("chatgpt", doctor["lifecycle"])


if __name__ == "__main__":
    unittest.main()

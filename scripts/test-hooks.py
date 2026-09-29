#!/usr/bin/env python3
import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("installer", Path(__file__).with_name("install-codex-hooks.py"))
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)

class HookInstallTests(unittest.TestCase):
    def test_preserves_other_hooks_and_is_idempotent(self):
        existing = {"description": "mine", "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "my-existing-hook"}]}]}}
        original = copy.deepcopy(existing)
        result = installer.merge(existing, "notification --codex-hook")
        self.assertEqual(result["description"], original["description"])
        self.assertEqual(result["hooks"]["Stop"][0], original["hooks"]["Stop"][0])
        self.assertEqual(installer.merge(copy.deepcopy(result), "notification --codex-hook"), result)
        removed = installer.merge(copy.deepcopy(result), "notification --codex-hook", remove=True)
        self.assertEqual(removed["hooks"]["Stop"], original["hooks"]["Stop"])
        self.assertTrue(all(not value for key, value in removed["hooks"].items() if key != "Stop"))

    def test_does_not_remove_another_install(self):
        document = installer.merge({}, "other-app --codex-hook")
        result = installer.merge(copy.deepcopy(document), "this-app --codex-hook", remove=True)
        self.assertEqual(result, document)

if __name__ == "__main__":
    unittest.main()

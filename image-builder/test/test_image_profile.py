#!/usr/bin/env python3
"""Named image profiles preserve production defaults and fail closed."""
import importlib.machinery
import importlib.util
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "builder"))
from image_profile import select

loader = importlib.machinery.SourceFileLoader("profile_mac_image_check", str(ROOT / "bin/mac-image-check"))
spec = importlib.util.spec_from_loader(loader.name, loader)
check = importlib.util.module_from_spec(spec)
loader.exec_module(check)


class ImageProfileTest(unittest.TestCase):
    def test_production_is_the_default_and_keeps_the_production_trust(self):
        production = select("production")
        self.assertEqual(production["trust"], ROOT / "builder/candidate-trust")
        self.assertIsNone(production["stage1"])
        self.assertIsNone(check.stage1_qualification.load())
        self.assertIn("linux-aurora-headers", check.required_image_packages())

    def test_developer_profile_is_explicit_and_has_its_own_trust_and_qualification(self):
        developer = select("j714s-developer")
        self.assertNotEqual(developer["trust"], select("production")["trust"])
        self.assertEqual(check.stage1_qualification.load(profile="j714s-developer")["qualified_machines"],
                         {"j714sap": ["27.3"]})
        self.assertEqual(check.required_image_packages("production") -
                         check.required_image_packages("j714s-developer"), {"linux-aurora-headers"})

    def test_unknown_profile_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "unknown image profile"):
            select("j714s-only-ish")
        with self.assertRaisesRegex(ValueError, "unknown image profile"):
            check.stage1_qualification.load(profile="j714s-only-ish")


if __name__ == "__main__":
    unittest.main()

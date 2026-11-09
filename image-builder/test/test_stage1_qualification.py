import importlib.util
import json
import hashlib
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("stage1_qualification", ROOT / "builder/stage1_qualification.py")
qualification = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qualification)


class Stage1QualificationTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "policy.json"
        self.policy = {
            "kind": "common-raw-v1",
            "qualified_machines": {"j714sap": ["27.3"]},
            "qualified_system_firmware": {"j714sap": ["mBoot-20457.60.65.0.1"]},
        }

    def test_source_default_qualifies_no_new_machines(self):
        policy = json.loads((ROOT / 'builder/candidate-trust/policy.json').read_text())
        self.assertIn('linux-aurora-headers', policy['boot_packages'])
        self.assertIsNone(qualification.load())

    def test_source_profile_contract(self):
        trust = ROOT / 'builder/profiles/j714s-developer/candidate-trust'
        policy = json.loads((trust / 'policy.json').read_text())
        self.assertEqual(qualification.load(profile='j714s-developer'), self.policy)
        self.assertEqual(qualification.J714S_KERNEL_VERSION, '7.3.0.aurora15.j714s2-1')
        self.assertEqual(qualification.J714S_KERNEL_RELEASE, '7.3.0-15.j714s2-1-j714s-candidate-ARCH')
        self.assertEqual(policy['primary_fingerprint'], '5C2445B5C37B584B5FC75D8711DFC2D674A06D68')
        self.assertEqual(policy['signing_fingerprint'], policy['primary_fingerprint'])
        self.assertEqual(policy['public_key_sha256'], hashlib.sha256((trust / 'public.asc').read_bytes()).hexdigest())
        self.assertNotIn('linux-aurora-headers', policy['boot_packages'])
        self.assertIn('t6050-j714s', policy['device_trees'])

    def test_exact_qualification_round_trips_and_only_adds_its_os_firmware(self):
        self.path.write_text(json.dumps(self.policy))
        self.assertEqual(qualification.load(self.path), self.policy)
        self.assertEqual(qualification.supported_firmware(["13.5", "26.6.2"], self.policy),
                         ["13.5", "26.6.2", "27.3"])
        self.assertNotIn("j714cap", qualification.load(self.path)["qualified_machines"])

    def test_missing_symlink_duplicate_or_malformed_input_is_not_silently_disabled(self):
        with self.assertRaises(ValueError):
            qualification.load(self.path)
        other = self.path.with_name("other")
        other.write_text("null")
        self.path.symlink_to(other)
        with self.assertRaises(ValueError):
            qualification.load(self.path)
        self.path.unlink()
        for value in ('{"kind":"a","kind":"b"}', '{', '[]'):
            with self.subTest(value=value):
                self.path.write_text(value)
                with self.assertRaises(ValueError):
                    qualification.load(self.path)

    def test_invalid_machine_or_system_firmware_constraints_are_refused(self):
        cases = [
            {**self.policy, "qualified_machines": {}},
            {**self.policy, "qualified_machines": {"apple,j714s": ["27.3"]}},
            {**self.policy, "qualified_machines": {"j714sap": []}},
            {**self.policy, "qualified_machines": {"j714sap": [None]}},
            {**self.policy, "qualified_system_firmware": {"j714cap": ["mBoot-20457.60.65.0.1"]}},
            {**self.policy, "qualified_system_firmware": {"j714sap": []}},
            {**self.policy, "qualified_system_firmware": {"j714sap": ["mBoot-*"]}},
            {**self.policy, "qualified_system_firmware": {"j714sap": [None]}},
            {**self.policy, "enabled": True},
        ]
        for value in cases:
            with self.subTest(value=value):
                self.path.write_text(json.dumps(value))
                with self.assertRaises(ValueError):
                    qualification.load(self.path)


if __name__ == "__main__":
    unittest.main()

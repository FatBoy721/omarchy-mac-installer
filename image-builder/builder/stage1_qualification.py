"""Read the reviewed common Stage 1 qualification used by this image source.

This is the engine's existing aurora_stage1 metadata contract, not a device
admission list. The shipped null policy qualifies no new machines.
"""
from __future__ import annotations

import json
from pathlib import Path
import re
import hashlib
import subprocess
import shlex
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from image_profile import select as select_image_profile
COMMON_STAGE1 = "esp/aurora/stage1.bin"
DEVICE_CLASS = re.compile(r"j[0-9]+[a-z]*ap\Z")
SYSTEM_FIRMWARE = re.compile(r"(?:mBoot|iBoot)-[0-9]+(?:\.[0-9]+)*\Z")
J714S_KERNEL_VERSION = "7.3.0.aurora15.j714s2-1"
J714S_KERNEL_RELEASE = "7.3.0-15.j714s2-1-j714s-candidate-ARCH"
J714S_ARGUMENTS = ("macsmc.m5_pcio_budget=2", "macsmc.m5_n1_budget=3")


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate Stage 1 qualification key")
        result[key] = value
    return result


def load(path: Path | None = None, profile: str = "production") -> dict | None:
    if path is None:
        path = select_image_profile(profile)["stage1"]
        if path is None:
            return None
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 8192:
        raise ValueError("missing or unsafe Stage 1 qualification policy")
    document = json.loads(path.read_text(), object_pairs_hook=_unique_object)
    if document is None:
        return None
    required = {"kind", "qualified_machines"}
    if (not isinstance(document, dict) or not required <= document.keys()
            or document.keys() - required - {"qualified_system_firmware"}
            or document["kind"] != "common-raw-v1"):
        raise ValueError("invalid Stage 1 qualification contract")
    machines = document["qualified_machines"]
    if not isinstance(machines, dict) or not machines:
        raise ValueError("Stage 1 qualification must name exact machines")
    for board, versions in machines.items():
        if (not DEVICE_CLASS.fullmatch(board) or not isinstance(versions, list) or not versions
                or not all(isinstance(version, str) and version and len(version) <= 128
                           and all(0x20 <= ord(character) < 0x7f for character in version)
                           for version in versions)
                or len(set(versions)) != len(versions)):
            raise ValueError("invalid Stage 1 machine/OS firmware qualification")
    if "qualified_system_firmware" in document:
        system = document["qualified_system_firmware"]
        if not isinstance(system, dict) or not system or system.keys() - machines.keys():
            raise ValueError("invalid Stage 1 system firmware qualification")
        for versions in system.values():
            if (not isinstance(versions, list) or not versions
                    or not all(isinstance(version, str) and SYSTEM_FIRMWARE.fullmatch(version)
                               for version in versions)
                    or len(set(versions)) != len(versions)):
                raise ValueError("invalid Stage 1 system firmware qualification")
    expected_arguments(document)
    return document


def supported_firmware(base: list[str], policy: dict | None) -> list[str]:
    if policy is None:
        return base
    return sorted(set(base) | {version for versions in policy["qualified_machines"].values()
                              for version in versions})


def expected_arguments(policy: dict | None) -> tuple[str, ...]:
    if policy is None or "j714sap" not in policy["qualified_machines"]:
        return ()
    if (policy["qualified_machines"] != {"j714sap": ["27.3"]}
            or policy.get("qualified_system_firmware") != {"j714sap": ["mBoot-20457.60.65.0.1"]}):
        raise ValueError("J714s budgets require the exact single-board candidate firmware profile")
    return J714S_ARGUMENTS


def _inside_file(root: Path, relative: str) -> Path:
    path = root / relative
    if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(root.resolve()):
        raise ValueError("missing or unsafe candidate kernel file: " + relative)
    return path


def seed_cmdline(root: Path, candidates: Path, profile: str = "production") -> None:
    """Seed only the exact private candidate, before its first normal UKI.

    The outer builder has authenticated/imported this set. Recheck archive
    identity and its installed kernel/DTB bytes, not the build host's DT.
    """
    if root.resolve() == Path("/"):
        raise ValueError("refusing to seed the running root")
    arguments = expected_arguments(load(profile=profile))
    if not arguments:
        return
    summary = json.loads((candidates / "import.json").read_text())
    packages = [entry for entry in summary["packages"] if entry.get("name") == "linux-aurora"]
    if len(packages) != 1 or packages[0].get("version") != J714S_KERNEL_VERSION:
        raise ValueError("J714s budgets require the exact candidate linux-aurora package")
    package = packages[0]
    name = package["filename"]
    if not isinstance(name, str) or Path(name).name != name or name in (".", ".."):
        raise ValueError("invalid candidate kernel archive name")
    archive = _inside_file(candidates, name)
    with archive.open("rb") as stream:
        if hashlib.file_digest(stream, "sha256").hexdigest() != package.get("sha256"):
            raise ValueError("candidate kernel archive digest mismatch")
    directory = "usr/lib/modules/" + J714S_KERNEL_RELEASE + "/"
    for member in (directory + "pkgbase", directory + "vmlinuz", directory + "dtbs/t6050-j714s.dtb"):
        installed = _inside_file(root, member).read_bytes()
        supplied = subprocess.check_output(["bsdtar", "-xOf", str(archive), member])
        if not installed or installed != supplied:
            raise ValueError("candidate kernel file differs from its package: " + member)
        if member.endswith("/pkgbase") and installed != b"linux-aurora\n":
            raise ValueError("candidate kernel has the wrong pkgbase")
    grub = _inside_file(root, "etc/default/grub")
    data = grub.read_text()
    baseline = 'GRUB_CMDLINE_LINUX="zswap.enabled=0 rootfstype=btrfs"'
    assignments = [line for line in data.splitlines() if re.match(
        r"^\s*(?:export\s+)?GRUB_CMDLINE_LINUX\s*\+?=", line)]
    if assignments != [baseline] or any(word in data.replace("-", "_") for word in
            ("macsmc.m5_pcio_budget=", "macsmc.m5_n1_budget=")):
        raise ValueError("candidate finalizer command line is not the normal baseline")
    data = data.replace(baseline, baseline[:-1] + " " + " ".join(arguments) + '"')
    grub.write_text(data)


def check_arguments(cmdline: str, profile: str = "production") -> None:
    expected = expected_arguments(load(profile=profile))
    if "'" in cmdline or "\\" in cmdline:
        raise ValueError("candidate command line quotes or escapes a word")
    words = shlex.split(cmdline)
    # The kernel treats '-' and '_' as equivalent in parameter names. An
    # alias must not evade the duplicate/changed-budget check.
    actual = [word for word in words if word.split("=", 1)[0].replace("-", "_") in
              ("macsmc.m5_pcio_budget", "macsmc.m5_n1_budget")]
    if sorted(actual) != sorted(expected):
        raise ValueError("UKI budgets do not match the reviewed single-board candidate profile")


if __name__ == "__main__":
    try:
        if len(sys.argv) == 1:
            print(json.dumps(load(), separators=(",", ":"), sort_keys=True))
        elif len(sys.argv) == 3 and sys.argv[1] == "--profile":
            print(json.dumps(load(profile=sys.argv[2]), separators=(",", ":"), sort_keys=True))
        elif len(sys.argv) == 6 and sys.argv[1] == "seed-cmdline" and sys.argv[4] == "--profile":
            seed_cmdline(Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[5])
        else:
            raise ValueError("invalid Stage 1 qualification command")
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))

#!/usr/bin/env python3
"""Verify distinct local builds satisfy each other's stable code requirement."""
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent


def command(args):
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stderr.strip())
    return result


with tempfile.TemporaryDirectory(prefix="notification-signing-test-") as directory:
    temporary = Path(directory)
    apps = []
    for version in (0, 1):
        app = temporary / f"Version{version}.app"
        contents = app / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "me.leiguoguo.notification",
            "CFBundleExecutable": "Notification",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": str(version + 1),
        }))
        source = temporary / f"version{version}.c"
        source.write_text(f"int main(void) {{ return {version}; }}\n")
        command(["/usr/bin/clang", str(source), "-o", str(contents / "MacOS/Notification")])
        command(["python3", str(ROOT / "scripts/local-signing.py"), "sign", str(app)])
        apps.append(app)
    requirements = []
    hashes = []
    for app in apps:
        result = command(["/usr/bin/codesign", "-dvvv", "-r-", str(app)])
        detail = result.stdout + result.stderr
        requirements.append(re.search(r"^designated => (.+)$", detail, re.MULTILINE).group(1))
        hashes.append(re.search(r"^CDHash=(.+)$", detail, re.MULTILINE).group(1))
    assert hashes[0] != hashes[1], "Fixture builds must actually differ"
    assert requirements[0] == requirements[1], "Identity must stay stable across different builds"
    assert "cdhash" not in requirements[0], "Identity must not depend on the executable hash"
    for app in apps:
        for requirement in requirements:
            command(["/usr/bin/codesign", "--verify", "--strict", "-R", "=" + requirement, str(app)])
    print("PASS: two distinct executables have different code hashes and the same certificate-based identity")
    print("PASS: both builds satisfy each other's designated requirement")

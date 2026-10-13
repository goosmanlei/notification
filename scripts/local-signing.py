#!/usr/bin/env python3
"""Keep one local signing identity across builds; never fall back to ad-hoc signing."""
import argparse
import fcntl
import hashlib
import os
from pathlib import Path
import plistlib
import secrets
import shlex
import ssl
import subprocess
import sys
import tempfile


STORE = Path.home() / "Library/Application Support/Notification/Signing"
KEYCHAIN = STORE / "notification-signing.keychain-db"
PASSWORD = STORE / "keychain-password"
CERTIFICATE = STORE / "certificate.pem"
BUNDLE_ID = "me.leiguoguo.notification"


def run(args, *, env=None, sensitive=()):
    result = subprocess.run(args, capture_output=True, text=True, env=env)
    if result.returncode:
        error = result.stderr.strip()
        for value in sensitive:
            error = error.replace(value, "[redacted]")
        raise RuntimeError(f"{Path(args[0]).name} failed: {error}")
    return result.stdout


def identity():
    # The public certificate's SHA-1 is the selector understood by codesign.
    pem = CERTIFICATE.read_text()
    return hashlib.sha1(ssl.PEM_cert_to_DER_cert(pem)).hexdigest().upper()


def initialize():
    if any(path.exists() for path in (KEYCHAIN, PASSWORD, CERTIFICATE)):
        if not all(path.exists() for path in (KEYCHAIN, PASSWORD, CERTIFICATE)):
            raise RuntimeError("Local signing setup is incomplete; do not replace its identity automatically.")
        print("Local signing identity already exists:", identity())
        return
    password = secrets.token_urlsafe(48)
    PASSWORD.write_text(password)
    PASSWORD.chmod(0o600)
    previous_search = shlex.split(run(["/usr/bin/security", "list-keychains", "-d", "user"]))
    try:
        run(["/usr/bin/security", "create-keychain", "-p", password, str(KEYCHAIN)], sensitive=(password,))
    finally:
        current_search = shlex.split(run(["/usr/bin/security", "list-keychains", "-d", "user"]))
        if current_search != previous_search:
            run(["/usr/bin/security", "list-keychains", "-d", "user", "-s", *previous_search])
    run(["/usr/bin/security", "set-keychain-settings", "-lut", "21600", str(KEYCHAIN)])
    run(["/usr/bin/security", "unlock-keychain", "-p", password, str(KEYCHAIN)], sensitive=(password,))
    with tempfile.TemporaryDirectory(prefix="setup-", dir=STORE) as directory:
        temporary = Path(directory)
        config = temporary / "certificate.cnf"
        config.write_text("""[req]
prompt = no
distinguished_name = subject
x509_extensions = extensions
[subject]
CN = Notification Local Signing
[extensions]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
""")
        key = temporary / "private-key.pem"
        certificate = temporary / "certificate.pem"
        package = temporary / "identity.p12"
        run(["/usr/bin/openssl", "req", "-new", "-x509", "-newkey", "rsa:3072", "-nodes",
             "-sha256", "-days", "3650", "-config", str(config), "-keyout", str(key), "-out", str(certificate)])
        environment = dict(os.environ, NOTIFICATION_PKCS12_PASSWORD=password)
        run(["/usr/bin/openssl", "pkcs12", "-export", "-inkey", str(key), "-in", str(certificate),
             "-name", "Notification Local Signing", "-out", str(package),
             "-passout", "env:NOTIFICATION_PKCS12_PASSWORD"], env=environment, sensitive=(password,))
        run(["/usr/bin/security", "import", str(package), "-k", str(KEYCHAIN), "-f", "pkcs12",
             "-P", password, "-x", "-T", "/usr/bin/codesign"], sensitive=(password,))
        # Only this dedicated keychain's signing key is affected.
        run(["/usr/bin/security", "set-key-partition-list", "-S", "apple-tool:,codesign:", "-s",
             "-k", password, str(KEYCHAIN)], sensitive=(password,))
        CERTIFICATE.write_bytes(certificate.read_bytes())
        CERTIFICATE.chmod(0o600)
    KEYCHAIN.chmod(0o600)
    print("Created local signing identity:", identity())


def trust():
    if not all(path.exists() for path in (KEYCHAIN, PASSWORD, CERTIFICATE)):
        raise RuntimeError("Local signing identity missing. Run: python3 scripts/local-signing.py init")
    # This may require the user to approve a native authentication dialog.
    run(["/usr/bin/security", "add-trusted-cert", "-r", "trustRoot", "-p", "codeSign",
         "-k", str(KEYCHAIN), str(CERTIFICATE)])
    print("Local certificate trusted for code signing only:", identity())


def sign(app):
    if not all(path.exists() for path in (KEYCHAIN, PASSWORD, CERTIFICATE)):
        raise RuntimeError("Local signing identity missing. Run: python3 scripts/local-signing.py init")
    with (app / "Contents/Info.plist").open("rb") as file:
        if plistlib.load(file).get("CFBundleIdentifier") != BUNDLE_ID:
            raise RuntimeError("This signing identity is only for the Notification app bundle.")
    password = PASSWORD.read_text()
    run(["/usr/bin/security", "unlock-keychain", "-p", password, str(KEYCHAIN)], sensitive=(password,))
    run(["/usr/bin/openssl", "x509", "-in", str(CERTIFICATE), "-checkend", "0", "-noout"])
    # codesign requires identities to be in the user's search list, even with --keychain.
    search = shlex.split(run(["/usr/bin/security", "list-keychains", "-d", "user"]))
    if str(KEYCHAIN) not in search:
        run(["/usr/bin/security", "list-keychains", "-d", "user", "-s", *search, str(KEYCHAIN)])
    fingerprint = identity()
    requirement = f'designated => identifier "{BUNDLE_ID}" and certificate leaf = H"{fingerprint}"'
    run(["/usr/bin/codesign", "--force", "--sign", fingerprint, "--keychain", str(KEYCHAIN),
         "--identifier", BUNDLE_ID, "--requirements", "=" + requirement, "--timestamp=none", str(app)])
    run(["/usr/bin/codesign", "--verify", "--strict", str(app)])
    print("Signed with fixed local identity:", fingerprint)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["init", "trust", "sign"])
    parser.add_argument("app", nargs="?", type=Path)
    args = parser.parse_args()
    if args.action == "sign" and args.app is None:
        parser.error("sign requires an app path")
    os.umask(0o077)
    STORE.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (STORE / "setup.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if args.action == "init":
            initialize()
        elif args.action == "trust":
            trust()
        else:
            sign(args.app)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)

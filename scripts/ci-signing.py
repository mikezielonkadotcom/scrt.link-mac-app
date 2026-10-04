"""Load step-scoped CI secrets into a disposable Keychain without logging them."""
import base64
import fcntl
import os
from pathlib import Path
import pty
import re
import select
import subprocess
import sys
import termios
import time


def fail(message):
    sys.exit(message)


def command(arguments, environment=None):
    result = subprocess.run(arguments, env=environment, capture_output=True)
    if result.returncode:
        fail(f"{Path(arguments[0]).name} failed. Credential output suppressed.")
    return result.stdout


def store_notary_password(password, keychain):
    # notarytool's documented secure interactive prompt keeps the password out
    # of argv. The PTY has echo disabled before the child starts.
    master, slave = pty.openpty()
    attributes = termios.tcgetattr(slave)
    attributes[3] &= ~(termios.ECHO | termios.ECHONL)
    termios.tcsetattr(slave, termios.TCSANOW, attributes)
    pid = os.fork()
    if pid == 0:
        os.close(master)
        os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
        for descriptor in (0, 1, 2):
            os.dup2(slave, descriptor)
        if slave > 2:
            os.close(slave)
        os.execvp("xcrun", [
            "xcrun", "notarytool", "store-credentials", os.environ["NOTARY_PROFILE"],
            "--apple-id", os.environ["APPLE_ID"],
            "--team-id", os.environ["TEAM_ID"], "--keychain", keychain,
        ])
    os.close(slave)
    seen = b""
    sent = False
    deadline = time.monotonic() + 120
    status = None
    reached_eof = False
    try:
        while time.monotonic() < deadline:
            if select.select([master], [], [], 1)[0]:
                try:
                    chunk = os.read(master, 8192)
                except OSError:
                    reached_eof = True
                    break
                if not chunk:
                    reached_eof = True
                    break
                seen = (seen + chunk)[-65536:]
                if not sent and re.search(rb"password[^\r\n]*:", seen, re.I):
                    os.write(master, (password + "\n").encode())
                    sent = True
            else:
                done, child_status = os.waitpid(pid, os.WNOHANG)
                if done:
                    status = child_status
                    break
        if status is None:
            done, child_status = os.waitpid(pid, 0 if reached_eof else os.WNOHANG)
            if not done:
                os.kill(pid, 15)
                _, child_status = os.waitpid(pid, 0)
            status = child_status
    finally:
        os.close(master)
    if not sent or os.waitstatus_to_exitcode(status) != 0:
        fail("Apple notarization credential validation failed. Secret output suppressed.")
    print("Notarization credentials validated and saved to the temporary Keychain.")


def main():
    if os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("RUNNER_OS") != "macOS":
        fail("Signing preparation is restricted to the GitHub macOS runner.")
    # Remove source secrets from the environment before spawning child tools.
    certificate_base64 = os.environ.pop("APPLE_CERTIFICATE_P12_BASE64", "")
    certificate_password = os.environ.pop("APPLE_CERTIFICATE_PASSWORD", "")
    notary_password = os.environ.pop("APPLE_NOTARY_PASSWORD", "")
    if not all((certificate_base64, certificate_password, notary_password)):
        fail("The apple-signing environment is missing a required secret.")
    if not re.fullmatch(r"[a-zA-Z]{4}(?:-[a-zA-Z]{4}){3}", notary_password):
        fail("Notarization password must be an Apple app-specific password.")
    keychain = os.environ["NOTARY_KEYCHAIN"]
    certificate_path = Path(os.environ["RUNNER_TEMP"]) / "scrt-link-certificate.p12"
    try:
        certificate = base64.b64decode(certificate_base64, validate=True)
    except ValueError:
        fail("The signing certificate secret is not valid Base64.")
    descriptor = os.open(certificate_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as output:
        output.write(certificate)
    try:
        # Empty password on an ephemeral runner-only Keychain; the P12 itself
        # is encrypted. No saved password is placed in a process argument.
        command(["security", "create-keychain", "-p", "", keychain])
        command(["security", "set-keychain-settings", "-lut", "21600", keychain])
        command(["security", "unlock-keychain", "-p", "", keychain])
        environment = dict(os.environ, CI_CERTIFICATE_PATH=str(certificate_path),
                           APPLE_CERTIFICATE_PASSWORD=certificate_password)
        command(["swift", "scripts/import-signing.swift"], environment)
        command(["security", "set-key-partition-list", "-S", "apple-tool:,apple:",
                 "-s", "-k", "", keychain])
        command(["security", "list-keychains", "-d", "user", "-s", keychain])
        identities = command(["security", "find-identity", "-v", "-p", "codesigning", keychain])
        if os.environ["DEVELOPER_ID"].encode() not in identities:
            fail("The certificate does not match the required Developer ID identity.")
        print("Developer ID identity verified.")
        store_notary_password(notary_password, keychain)
    finally:
        certificate_path.unlink(missing_ok=True)


if __name__ == "__main__":
    main()

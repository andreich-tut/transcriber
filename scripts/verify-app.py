#!/usr/bin/env python3
"""Check the distributable bundle without reading any user credentials."""
import plistlib
import re
import subprocess
import sys
from pathlib import Path


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verify(app):
    require(app.is_dir(), "Application bundle is missing")
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    require(info.get("CFBundleIdentifier") == "local.transcriber", "Unexpected bundle identifier")
    for key in ("CFBundleName", "CFBundleDisplayName", "CFBundleExecutable"):
        require(info.get(key) == "Transcriber", "Unexpected app name: " + key)

    obsolete = re.compile(rb"daily[ ._-]*transcriber", re.I)
    # The public framework contains paths from its generic GitHub Actions runner.
    home_path = re.compile(rb"/(?:Users|home)/(?!runner/)[^/\s\x00]+/")
    private_key = re.compile(rb"-----BEGIN (?:[A-Z]+ )*PRIVATE KEY-----")
    forbidden_extensions = {".pem", ".key", ".p12", ".pfx", ".mobileprovision", ".provisionprofile",
                            ".wav", ".m4a", ".mp3", ".aiff", ".flac", ".mp4", ".mov"}
    count = 0
    for path in app.rglob("*"):
        relative = str(path.relative_to(app))
        require(not obsolete.search(relative.encode()), "Obsolete branding in bundle filename")
        if path.is_symlink():
            require(path.resolve().is_relative_to(app.resolve()), "External symlink: " + relative)
            continue
        if not path.is_file():
            continue
        require(path.suffix.lower() not in forbidden_extensions, "Private file type: " + relative)
        require(not path.name.startswith((".env", "credentials", "secrets", "._")),
                "Private or metadata file: " + relative)
        data = path.read_bytes()
        for pattern, label in ((obsolete, "Obsolete branding"), (home_path, "Developer home path"),
                               (private_key, "Private key")):
            require(not pattern.search(data), label + " in " + relative)
        count += 1

    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    framework = app / "Contents/Frameworks/whisper.framework"
    for signed in (app, framework):
        result = subprocess.run(["/usr/bin/codesign", "-dv", "--verbose=4", str(signed)],
                                check=True, capture_output=True, text=True)
        signature = result.stderr.splitlines()
        require("Signature=adhoc" in signature, "Expected an ad-hoc signature")
        require("TeamIdentifier=not set" in signature, "Unexpected signing team")
        require(not any(line.startswith("Authority=") for line in signature),
                "Unexpected signing certificate")
    print(f"Package verified: {count} files; neutral branding; no developer home paths or credential files; ad-hoc signatures, no team.")


if __name__ == "__main__":
    try:
        require(len(sys.argv) == 2, "Usage: verify-app.py path/to/Transcriber.app")
        verify(Path(sys.argv[1]))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit("Package verification failed: " + str(error))

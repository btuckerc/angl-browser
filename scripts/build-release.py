#!/usr/bin/env python3
"""Build a Developer ID-signed angl.app for a published release (mac-releases adapter).

Runs scripts/bundle.sh with the release identity, version and build number, and a secure
timestamp, then copies build/angl.app to --output. Notarizing is mac-releases' job.
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release", action="store_true", required=True)
    parser.add_argument("--identity", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build-number", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", args.version):
        parser.error("--version must be numeric X.Y.Z")
    if not re.fullmatch(r"[1-9][0-9]*", args.build_number):
        parser.error("--build-number must be a positive integer")
    if not args.output.is_absolute() or args.output.suffix != ".app":
        parser.error("--output must be an absolute path ending in .app")
    if os.path.lexists(args.output):
        parser.error(f"--output already exists: {args.output}")
    declared = (ROOT / "VERSION").read_text().strip()
    if args.version != declared:
        parser.error(f"--version {args.version} differs from VERSION ({declared}); bump VERSION and commit first")
    if sys.platform != "darwin":
        raise SystemExit("Release builds require macOS.")

    env = dict(os.environ, ANGL_SIGN_IDENTITY=args.identity, ANGL_VERSION=args.version,
               ANGL_BUILD_NUMBER=args.build_number, ANGL_RELEASE="1")
    subprocess.run([str(ROOT / "scripts/bundle.sh")], cwd=ROOT, env=env, check=True)
    subprocess.run(["ditto", str(ROOT / "build/angl.app"), str(args.output)], check=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())

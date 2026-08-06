#!/usr/bin/env python3
"""Unified MarketScanner build-identity contract (V1R4 §3.3).

This is the SINGLE source of the native-core digest algorithm. The
Xcode "MarketScanner Build Identity" script phase, the GitHub Actions
exact-sha job, the PC oracle and any verification step MUST all call
this script — no other hashing pipeline is allowed.

Digest contract (byte-exact, frozen):

    native_core_sha256 = SHA256(
        b"market_scanner_factor_graph.cpp\\0" + cpp_bytes +
        b"market_scanner_factor_graph.h\\0"   + h_bytes
    )

The embedded JSON always carries format/version, the app git SHA
(40 lowercase hex), the wave name and the native core SHA (64 lowercase
hex). A dirty tree or any malformed field fails closed (exit != 0);
`unknown` must never reach an eligible session.

Usage:
    market_scanner_build_identity.py emit --repo <root> [--out file]
    market_scanner_build_identity.py native-digest --repo <root>
    market_scanner_build_identity.py verify --repo <root> --identity <file>
"""

import argparse
import hashlib
import json
import os
import subprocess
import sys
import tempfile

FORMAT = "MarketScannerBuildIdentity"
VERSION = 2
CPP_REL = os.path.join("core", "MarketScannerFactorGraph", "market_scanner_factor_graph.cpp")
H_REL = os.path.join("core", "MarketScannerFactorGraph", "market_scanner_factor_graph.h")
WAVE_REL = os.path.join(".github", "marketscanner-repair-v2-wave.json")


def fail(message: str) -> None:
    sys.stderr.write("build-identity: %s\n" % message)
    sys.exit(1)


def native_core_digest(repo_root: str) -> str:
    cpp = os.path.join(repo_root, CPP_REL)
    header = os.path.join(repo_root, H_REL)
    for path in (cpp, header):
        if not os.path.isfile(path):
            fail("missing native core source: %s" % path)
    hasher = hashlib.sha256()
    hasher.update(b"market_scanner_factor_graph.cpp\0")
    with open(cpp, "rb") as handle:
        hasher.update(handle.read())
    hasher.update(b"market_scanner_factor_graph.h\0")
    with open(header, "rb") as handle:
        hasher.update(handle.read())
    return hasher.hexdigest()


def git_sha(repo_root: str, allow_dirty: bool) -> str:
    try:
        sha = subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=repo_root, check=True,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        ).stdout.decode().strip()
    except Exception:
        fail("git rev-parse HEAD failed")
    if len(sha) != 40 or any(c not in "0123456789abcdef" for c in sha):
        fail("HEAD is not a 40-char lowercase SHA: %r" % sha)
    if not allow_dirty:
        status = subprocess.run(
            ["git", "status", "--porcelain", "--untracked-files=no"],
            cwd=repo_root, check=True, stdout=subprocess.PIPE,
        ).stdout.decode()
        tracked_dirty = [
            line for line in status.splitlines()
            if line.strip() and not line[3:].strip().startswith(
                (".github/marketscanner-repair-v2-wave.json",
                 "docs/mobile-only/",
                 "docs/map-assisted-localization/reviews/CURRENT_REVIEW.md"))
        ]
        if tracked_dirty:
            fail("dirty tracked tree refuses build identity:\n%s"
                 % "\n".join(tracked_dirty[:10]))
    return sha


def wave_name(repo_root: str) -> str:
    path = os.path.join(repo_root, WAVE_REL)
    if not os.path.isfile(path):
        fail("wave json missing")
    with open(path, encoding="utf-8") as handle:
        wave = json.load(handle).get("wave", "")
    if not wave or not wave.startswith("mobile-only-v1r4-"):
        fail("wave name not the V1R4 wave: %r" % wave)
    return wave


def build_identity(repo_root: str, allow_dirty: bool) -> dict:
    identity = {
        "format": FORMAT,
        "version": VERSION,
        "app_git_sha": git_sha(repo_root, allow_dirty),
        "wave": wave_name(repo_root),
        "native_core_sha256": native_core_digest(repo_root),
    }
    validate_fields(identity)
    return identity


def validate_fields(identity: dict) -> None:
    if identity.get("format") != FORMAT:
        fail("bad format")
    if identity.get("version") != VERSION:
        fail("bad version")
    sha = identity.get("app_git_sha", "")
    if len(sha) != 40 or any(c not in "0123456789abcdef" for c in sha):
        fail("app_git_sha not 40 lowercase hex: %r" % sha)
    digest = identity.get("native_core_sha256", "")
    if len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
        fail("native_core_sha256 not 64 lowercase hex: %r" % digest)
    if not identity.get("wave"):
        fail("wave missing")


def atomic_write(path: str, content: bytes) -> None:
    directory = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(prefix=".build-identity.", dir=directory)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.rename(tmp, path)
        dir_fd = os.open(directory, os.O_RDONLY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["emit", "native-digest", "verify"])
    parser.add_argument("--repo", required=True)
    parser.add_argument("--out")
    parser.add_argument("--identity")
    parser.add_argument("--allow-dirty", action="store_true")
    args = parser.parse_args()
    repo = os.path.abspath(args.repo)

    if args.command == "native-digest":
        print(native_core_digest(repo))
        return
    if args.command == "emit":
        identity = build_identity(repo, args.allow_dirty)
        payload = (json.dumps(identity, indent=2, sort_keys=True) + "\n").encode()
        if args.out:
            atomic_write(args.out, payload)
        else:
            sys.stdout.write(payload.decode())
        return
    # verify
    if not args.identity or not os.path.isfile(args.identity):
        fail("--identity file required")
    with open(args.identity, "rb") as handle:
        embedded = json.loads(handle.read().decode("utf-8"))
    validate_fields(embedded)
    expected = build_identity(repo, allow_dirty=True)
    for key in ("app_git_sha", "wave", "native_core_sha256"):
        if embedded.get(key) != expected.get(key):
            fail("embedded %s=%r != checked-out %r" % (key, embedded.get(key), expected.get(key)))
    print("build identity verified")


if __name__ == "__main__":
    main()

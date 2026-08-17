#!/usr/bin/env python3
"""Unified MarketScanner build-identity and governance contract.

This is the SINGLE source of the native-core digest algorithm. The
Xcode "MarketScanner Build Identity" script phase, the GitHub Actions
exact-sha job, the PC oracle and any verification step MUST all call
this script — no other hashing pipeline is allowed.

Digest contract (byte-exact, frozen):

    native_core_sha256 = SHA256(
        b"market_scanner_factor_graph.cpp\\0" + cpp_bytes +
        b"market_scanner_factor_graph.h\\0"   + h_bytes
    )

The embedded version-4 JSON carries the exact governance descriptor
(`wave`, `branch`, `base_branch`, and its three SHA bindings), the app Git
SHA (40 lowercase hex), the native-core SHA-256 (64 lowercase hex), and the
build configuration / tracked-working-tree state. Debug and Release both
receive a traceable identity and execute the same scan path. Release remains
the only production-qualified configuration, while a dirty Debug build is
explicitly labelled instead of being blocked from end-to-end testing.
Unknown, missing, duplicate, unsafe, or malformed fields fail closed.

Usage:
    market_scanner_build_identity.py emit --repo <root> [--out file]
        [--configuration Debug|Release] [--allow-dirty]
    market_scanner_build_identity.py native-digest --repo <root>
    market_scanner_build_identity.py verify --repo <root> --identity <file>
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile

FORMAT = "MarketScannerBuildIdentity"
VERSION = 4
CPP_REL = os.path.join("core", "MarketScannerFactorGraph", "market_scanner_factor_graph.cpp")
H_REL = os.path.join("core", "MarketScannerFactorGraph", "market_scanner_factor_graph.h")
WAVE_REL = os.path.join(".github", "marketscanner-repair-v2-wave.json")
GOVERNANCE_KEYS = {
    "wave",
    "branch",
    "base_branch",
    "base_sha",
    "implementation_sha",
    "validation_sha",
}
IDENTITY_KEYS = GOVERNANCE_KEYS | {
    "format",
    "version",
    "app_git_sha",
    "native_core_sha256",
    "build_configuration",
    "working_tree_state",
    "production_eligible",
}
SAFE_GOVERNANCE_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,127}$")
LOWER_SHA_RE = re.compile(r"^[0-9a-f]{40}$")
LOWER_DIGEST_RE = re.compile(r"^[0-9a-f]{64}$")
UNBOUND_SHA_PLACEHOLDERS = {
    "implementation_sha": "<CODE_CONTRACT_TEST_BUILD_SHA>",
    "validation_sha": "<EVIDENCE_DOCS_SHA>",
}
BUILD_CONFIGURATIONS = {"debug", "release"}
WORKING_TREE_STATES = {"clean", "dirty"}
TRACKED_DIRTY_EXCLUSIONS = (
    ".github/marketscanner-repair-v2-wave.json",
    "docs/mobile-only/",
    "docs/map-assisted-localization/reviews/CURRENT_REVIEW.md",
)


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


def _tracked_dirty_lines(repo_root: str) -> list[str]:
    try:
        status = subprocess.run(
            ["git", "status", "--porcelain", "--untracked-files=no"],
            cwd=repo_root, check=True, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        ).stdout.decode()
    except Exception:
        fail("git status failed")
    return [
        line for line in status.splitlines()
        if line.strip()
        and not line[3:].strip().startswith(TRACKED_DIRTY_EXCLUSIONS)
    ]


def working_tree_state(repo_root: str) -> str:
    return "dirty" if _tracked_dirty_lines(repo_root) else "clean"


def canonical_build_configuration(value: object) -> str:
    if not isinstance(value, str):
        fail("build configuration is not a string: %r" % value)
    canonical = value.strip().lower()
    if canonical not in BUILD_CONFIGURATIONS:
        fail("unsupported build configuration: %r" % value)
    return canonical


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
        tracked_dirty = _tracked_dirty_lines(repo_root)
        if tracked_dirty:
            fail("dirty tracked tree refuses build identity:\n%s"
                 % "\n".join(tracked_dirty[:10]))
    return sha


def _strict_json_object(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            fail("governance descriptor contains duplicate field: %s" % key)
        result[key] = value
    return result


def _validate_safe_governance_name(value: object, field: str) -> str:
    if not isinstance(value, str) or not SAFE_GOVERNANCE_NAME_RE.fullmatch(value):
        fail("%s is not a safe non-empty governance name: %r" % (field, value))
    return value


def _validate_governance_sha(
    value: object,
    field: str,
    *,
    allow_unbound_placeholder: bool,
) -> str:
    if not isinstance(value, str):
        fail("%s is not a string" % field)
    if LOWER_SHA_RE.fullmatch(value):
        return value
    if allow_unbound_placeholder and value == UNBOUND_SHA_PLACEHOLDERS[field]:
        return value
    fail("%s is not a 40-char lowercase SHA or its exact unbound placeholder: %r"
         % (field, value))
    raise AssertionError("unreachable")


def validate_governance_descriptor(descriptor: object) -> dict:
    if not isinstance(descriptor, dict):
        fail("governance descriptor root must be an object")
    if set(descriptor) != GOVERNANCE_KEYS:
        fail("governance descriptor schema mismatch: expected=%r actual=%r"
             % (sorted(GOVERNANCE_KEYS), sorted(descriptor)))
    validated = {
        "wave": _validate_safe_governance_name(descriptor.get("wave"), "wave"),
        "branch": _validate_safe_governance_name(
            descriptor.get("branch"), "branch"),
        "base_branch": _validate_safe_governance_name(
            descriptor.get("base_branch"), "base_branch"),
        "base_sha": _validate_governance_sha(
            descriptor.get("base_sha"), "base_sha",
            allow_unbound_placeholder=False),
        "implementation_sha": _validate_governance_sha(
            descriptor.get("implementation_sha"), "implementation_sha",
            allow_unbound_placeholder=True),
        "validation_sha": _validate_governance_sha(
            descriptor.get("validation_sha"), "validation_sha",
            allow_unbound_placeholder=True),
    }
    return validated


def governance_descriptor(repo_root: str) -> dict:
    path = os.path.join(repo_root, WAVE_REL)
    if not os.path.isfile(path):
        fail("governance descriptor missing")
    try:
        with open(path, encoding="utf-8") as handle:
            descriptor = json.load(
                handle, object_pairs_hook=_strict_json_object)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail("governance descriptor cannot be read: %s" % error)
    return validate_governance_descriptor(descriptor)


def wave_name(repo_root: str) -> str:
    return governance_descriptor(repo_root)["wave"]


def build_identity(
    repo_root: str,
    allow_dirty: bool,
    build_configuration: str = "Release",
) -> dict:
    governance = governance_descriptor(repo_root)
    configuration = canonical_build_configuration(build_configuration)
    tree_state = working_tree_state(repo_root)
    if tree_state == "dirty" and (
        configuration == "release" or not allow_dirty
    ):
        # Reuse the detailed path diagnostics from the canonical Git gate.
        git_sha(repo_root, allow_dirty=False)
    identity = {
        "format": FORMAT,
        "version": VERSION,
        "app_git_sha": git_sha(repo_root, allow_dirty=True),
        "native_core_sha256": native_core_digest(repo_root),
        "build_configuration": configuration,
        "working_tree_state": tree_state,
        "production_eligible": (
            configuration == "release" and tree_state == "clean"
        ),
        **governance,
    }
    validate_fields(identity)
    return identity


def validate_fields(identity: dict) -> None:
    if not isinstance(identity, dict):
        fail("build identity root must be an object")
    if set(identity) != IDENTITY_KEYS:
        fail("build identity schema mismatch: expected=%r actual=%r"
             % (sorted(IDENTITY_KEYS), sorted(identity)))
    if identity.get("format") != FORMAT:
        fail("bad format")
    if identity.get("version") != VERSION:
        fail("bad version")
    sha = identity.get("app_git_sha", "")
    if not isinstance(sha, str) or not LOWER_SHA_RE.fullmatch(sha):
        fail("app_git_sha not 40 lowercase hex: %r" % sha)
    digest = identity.get("native_core_sha256", "")
    if not isinstance(digest, str) or not LOWER_DIGEST_RE.fullmatch(digest):
        fail("native_core_sha256 not 64 lowercase hex: %r" % digest)
    configuration = identity.get("build_configuration")
    if configuration != canonical_build_configuration(configuration):
        fail("build_configuration must use canonical lowercase form")
    tree_state = identity.get("working_tree_state")
    if tree_state not in WORKING_TREE_STATES:
        fail("working_tree_state must be clean or dirty: %r" % tree_state)
    if configuration == "release" and tree_state != "clean":
        fail("Release identity requires a clean tracked tree")
    production_eligible = identity.get("production_eligible")
    if type(production_eligible) is not bool:
        fail("production_eligible is not a Boolean")
    expected_eligibility = (
        configuration == "release" and tree_state == "clean"
    )
    if production_eligible != expected_eligibility:
        fail(
            "production_eligible inconsistent with configuration/tree state"
        )
    validate_governance_descriptor({
        key: identity.get(key) for key in GOVERNANCE_KEYS
    })


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
    parser.add_argument("--configuration", default=None)
    args = parser.parse_args()
    repo = os.path.abspath(args.repo)

    if args.command == "native-digest":
        print(native_core_digest(repo))
        return
    if args.command == "emit":
        identity = build_identity(
            repo,
            args.allow_dirty,
            build_configuration=args.configuration or "Release",
        )
        payload = (json.dumps(identity, indent=2, sort_keys=True) + "\n").encode()
        if args.out:
            atomic_write(args.out, payload)
        else:
            sys.stdout.write(payload.decode())
        return
    # verify
    if not args.identity or not os.path.isfile(args.identity):
        fail("--identity file required")
    try:
        with open(args.identity, "r", encoding="utf-8") as handle:
            embedded = json.load(
                handle, object_pairs_hook=_strict_json_object)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail("identity cannot be read: %s" % error)
    validate_fields(embedded)
    embedded_configuration = embedded.get("build_configuration")
    if args.configuration is not None:
        requested_configuration = canonical_build_configuration(
            args.configuration)
        if embedded_configuration != requested_configuration:
            fail(
                "embedded build_configuration=%r != requested %r"
                % (embedded_configuration, requested_configuration)
            )
    expected = build_identity(
        repo,
        allow_dirty=True,
        build_configuration=str(embedded_configuration),
    )
    for key in sorted(IDENTITY_KEYS - {"format", "version"}):
        if embedded.get(key) != expected.get(key):
            fail("embedded %s=%r != checked-out %r" % (key, embedded.get(key), expected.get(key)))
    print("build identity verified")


if __name__ == "__main__":
    main()

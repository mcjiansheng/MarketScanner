#!/usr/bin/env python3
"""MarketScanner build-version stamping (test-build discrimination only).


This script is the SINGLE source of the human-visible build stamp. The Xcode
"MarketScanner Version Stamp" script phase calls it AFTER the bundle
resources have been copied and BEFORE code signing, so it writes into the
built product and never dirties the source tree.

Scope boundary (important):

* CFBundleShortVersionString stays under human control as MARKETING_VERSION.
  This script never rewrites it.
* CFBundleVersion is stamped with the monotonically increasing Git commit
  count so two builds off the same marketing version remain distinguishable.
* MSBuildGitSHA / MSBuildVariant are additive diagnostics for testers.
* This script does NOT change CFBundleIdentifier. Parallel installation is
  decided by the MS_BUNDLE_ID_SUFFIX build setting alone; this script only
  records the variant that was requested.

Why stamping is not enough for parallel installation: iOS identifies an app
by CFBundleIdentifier, not by version. Two builds with different
CFBundleVersion values replace each other on the device. Passing
MS_BUNDLE_ID_SUFFIX (see build_ios_test_package.sh --variant) is the only
way to make two builds coexist.

Failure policy:

* A malformed variant or a missing target plist fails the build (fail
  closed) — a wrong identity is worse than a failed build.
* An unavailable Git repository degrades to the values already present in
  the built Info.plist and prints a warning. Version stamping must never
  turn a buildable source export into a build failure.

Usage:
    market_scanner_version_stamp.py stamp --repo <root> --info-plist <path>
        [--settings-root-plist <path>] [--variant <name>]
    market_scanner_version_stamp.py display --repo <root> [--variant <name>]
"""

# Xcode runs build phases with a minimal PATH where `python3` is the Xcode
# command line tools interpreter (Python 3.9 on current macOS). Deferred
# annotations keep this script importable on 3.9.
from __future__ import annotations

import argparse
import os
import plistlib
import re
import subprocess
import sys

SETTINGS_VERSION_KEY = "Version"
INFO_BUILD_NUMBER_KEY = "CFBundleVersion"
INFO_GIT_SHA_KEY = "MSBuildGitSHA"
INFO_VARIANT_KEY = "MSBuildVariant"
FALLBACK_BUILD_NUMBER = "1"
UNKNOWN_SHA = "unknown"
DIRTY_SUFFIX = "+"
VARIANT_SEPARATOR = " · "
# A variant is appended verbatim to CFBundleIdentifier and CFBundleDisplayName,
# so it may only contain alphanumerics, hyphen and period, never whitespace.
# A leading "." or "-" is the recommended separator (".b1" -> "...dev.b1");
# the character after it must be alphanumeric so the suffix is never a bare
# separator and never produces an empty bundle-id component.
SAFE_VARIANT_RE = re.compile(r"^[.-]?[A-Za-z0-9][A-Za-z0-9._-]{0,62}$")
# Apple requires CFBundleVersion to be a period-separated list of non-negative
# integers, so an explicit override must match this and nothing else.
SAFE_BUILD_NUMBER_RE = re.compile(r"^[0-9]+(\.[0-9]+){0,2}$")


def fail(message: str) -> None:
    sys.stderr.write("version-stamp: %s\n" % message)
    sys.exit(1)


def _git(repo_root: str, args: list[str]) -> str | None:
    try:
        result = subprocess.run(
            ["git", *args],
            cwd=repo_root,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.CalledProcessError):
        return None
    return result.stdout.decode("utf-8", "replace").strip()


def build_number(repo_root: str) -> str | None:
    """Monotonically increasing commit count, or None when Git is absent."""
    value = _git(repo_root, ["rev-list", "--count", "HEAD"])
    if not value or not value.isdigit() or int(value) <= 0:
        return None
    return value


def canonical_build_number(value: str) -> str:
    """Validates an explicit CFBundleVersion override.

    The commit count goes down when checking out an older branch, which can
    make iOS refuse to install over a newer build of the same bundle
    identifier. `MS_BUILD_NUMBER` is the escape hatch for that case; it is
    validated strictly so a typo cannot produce an installable-looking but
    malformed version.
    """
    if value and not SAFE_BUILD_NUMBER_RE.fullmatch(value):
        fail("build number must be 1-3 dot-separated non-negative integers: "
             "%r" % value)
    return value


def git_short_sha(repo_root: str, length: int = 7) -> str | None:
    value = _git(repo_root, ["rev-parse", "--short=%d" % length, "HEAD"])
    if not value or not re.fullmatch(r"[0-9a-f]+", value):
        return None
    return value


def tracked_tree_is_dirty(repo_root: str) -> bool:
    value = _git(
        repo_root, ["status", "--porcelain", "--untracked-files=no"])
    if value is None:
        return False
    return bool(value.strip())


def canonical_variant(value: str) -> str:
    """Validates the optional parallel-install variant.

    Empty means "no variant", which keeps the bundle identifier and the
    display name byte-identical to the historical defaults.
    """
    if value and not SAFE_VARIANT_RE.fullmatch(value):
        fail(
            "variant must be empty or match "
            "[.-]?[A-Za-z0-9][A-Za-z0-9._-]{0,62}: %r" % value
        )
    return value


def resolve_stamp(
    repo_root: str,
    fallback_build_number: str,
    build_number_override: str = "",
) -> dict:
    """Builds the stamp payload, degrading safely when Git is unavailable."""
    sha = git_short_sha(repo_root)
    number = build_number_override or build_number(repo_root)
    if number is None or sha is None:
        sys.stderr.write(
            "version-stamp: warning: Git metadata unavailable; keeping "
            "CFBundleVersion=%s and marking SHA unknown\n"
            % fallback_build_number
        )
    return {
        "build_number": number or fallback_build_number,
        "git_sha": sha if sha is not None else UNKNOWN_SHA,
        "dirty": tracked_tree_is_dirty(repo_root),
    }


def short_sha_display(stamp: dict) -> str:
    return stamp["git_sha"] + (DIRTY_SUFFIX if stamp["dirty"] else "")


def display_string(marketing_version: str, stamp: dict, variant: str) -> str:
    """Single human-visible format shared by Settings and the in-app label."""
    parts = [marketing_version, stamp["build_number"], short_sha_display(stamp)]
    if variant:
        parts.append(variant)
    return "%s (%s)" % (parts[0], VARIANT_SEPARATOR.join(parts[1:]))


def _load_plist(path: str) -> tuple[dict, int]:
    if not os.path.isfile(path):
        fail("target plist missing: %s" % path)
    try:
        with open(path, "rb") as handle:
            head = handle.read(6)
            handle.seek(0)
            fmt = (
                plistlib.FMT_BINARY
                if head == b"bplist"
                else plistlib.FMT_XML
            )
            return plistlib.load(handle), fmt
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        fail("cannot read plist %s: %s" % (path, error))
    raise AssertionError("unreachable")


def _write_plist(path: str, payload: dict, fmt: int) -> None:
    try:
        with open(path, "wb") as handle:
            plistlib.dump(payload, handle, fmt=fmt, sort_keys=False)
    except (OSError, ValueError) as error:
        fail("cannot write plist %s: %s" % (path, error))


def stamp_settings_root_plist(path: str, display: str) -> None:
    payload, fmt = _load_plist(path)
    items = payload.get("PreferenceSpecifiers")
    if not isinstance(items, list):
        fail("Settings root plist has no PreferenceSpecifiers array: %s" % path)
    matches = [
        index
        for index, item in enumerate(items)
        if isinstance(item, dict) and item.get("Key") == SETTINGS_VERSION_KEY
    ]
    if len(matches) != 1:
        fail(
            "expected exactly one Settings item with Key=%r, found %d in %s"
            % (SETTINGS_VERSION_KEY, len(matches), path)
        )
    items[matches[0]]["DefaultValue"] = display
    _write_plist(path, payload, fmt)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["stamp", "display"])
    parser.add_argument("--repo", required=True)
    parser.add_argument("--info-plist")
    parser.add_argument("--settings-root-plist")
    parser.add_argument("--variant", default="")
    parser.add_argument("--build-number", default="")
    parser.add_argument(
        "--marketing-version", default=os.environ.get("MARKETING_VERSION", ""))
    args = parser.parse_args()

    repo = os.path.abspath(args.repo)
    variant = canonical_variant(args.variant)
    override = canonical_build_number(args.build_number)

    if args.command == "display":
        stamp = resolve_stamp(repo, FALLBACK_BUILD_NUMBER, override)
        print(display_string(args.marketing_version, stamp, variant))
        return

    if not args.info_plist:
        fail("--info-plist is required for stamp")

    info_path = os.path.abspath(args.info_plist)
    payload, fmt = _load_plist(info_path)
    fallback = str(payload.get(INFO_BUILD_NUMBER_KEY) or FALLBACK_BUILD_NUMBER)
    stamp = resolve_stamp(repo, fallback, override)
    payload[INFO_BUILD_NUMBER_KEY] = stamp["build_number"]
    payload[INFO_GIT_SHA_KEY] = short_sha_display(stamp)
    payload[INFO_VARIANT_KEY] = variant
    _write_plist(info_path, payload, fmt)

    marketing = str(payload.get("CFBundleShortVersionString") or "")
    display = display_string(marketing, stamp, variant)
    if args.settings_root_plist:
        stamp_settings_root_plist(
            os.path.abspath(args.settings_root_plist), display)
    print("version stamp: %s" % display)


if __name__ == "__main__":
    main()

from __future__ import annotations

from contextlib import redirect_stderr
import io
import plistlib
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

from tools.Qualification import market_scanner_version_stamp as stamp


ROOT = Path(__file__).resolve().parents[3]
PBXPROJ = ROOT / "app/ios/RTABMapApp.xcodeproj/project.pbxproj"
INFO_PLIST = ROOT / "app/ios/RTABMapApp/Info.plist"
BUILD_SCRIPT = ROOT / "releases/ios/build_ios_test_package.sh"

TARGET_ID = "4EE015C1259A2AF0008CCE65"
RESOURCES_PHASE = "4EE015C0259A2AF0008CCE65"
VERSION_STAMP_PHASE = "4EA4BDE12635BD4500706703"
IDENTITY_PHASE = "4EA7C3000000000000300001"


def make_repo(root: Path) -> None:
    root.mkdir(parents=True, exist_ok=True)
    (root / "probe.txt").write_text("fixture\n", encoding="utf-8")
    for args in (
        ["git", "init", "-q"],
        ["git", "config", "user.email", "stamp-test@example.invalid"],
        ["git", "config", "user.name", "Stamp Test"],
        ["git", "add", "."],
        ["git", "commit", "-q", "-m", "stamp fixture"],
    ):
        subprocess.run(args, cwd=root, check=True)


def write_info_plist(path: Path, build_number: str = "1") -> None:
    payload = {
        "CFBundleShortVersionString": "0.22.0",
        "CFBundleVersion": build_number,
        "CFBundleIdentifier": "com.xiehaotian.marketscanner.dev",
    }
    with open(path, "wb") as handle:
        plistlib.dump(payload, handle, fmt=plistlib.FMT_XML)


def write_settings_plist(path: Path, decoy_first: bool = False) -> None:
    version_item = {
        "Type": "PSTitleValueSpecifier",
        "Title": "Version",
        "Key": "Version",
        "DefaultValue": "0.22.0",
    }
    decoy = {"Type": "PSGroupSpecifier", "Title": "Decoy"}
    items = [decoy, version_item] if decoy_first else [version_item]
    with open(path, "wb") as handle:
        plistlib.dump(
            {"PreferenceSpecifiers": items}, handle, fmt=plistlib.FMT_XML)


def read_plist(path: Path) -> dict:
    with open(path, "rb") as handle:
        return plistlib.load(handle)


class VersionStampFormatTests(unittest.TestCase):
    def test_display_string_without_variant(self) -> None:
        text = stamp.display_string(
            "0.22.0",
            {"build_number": "1428", "git_sha": "a1b2c3d", "dirty": False},
            "",
        )
        self.assertEqual(text, "0.22.0 (1428 · a1b2c3d)")

    def test_display_string_with_variant(self) -> None:
        text = stamp.display_string(
            "0.22.0",
            {"build_number": "1428", "git_sha": "a1b2c3d", "dirty": False},
            ".b1",
        )
        self.assertEqual(text, "0.22.0 (1428 · a1b2c3d · .b1)")

    def test_display_string_marks_dirty_tree(self) -> None:
        text = stamp.display_string(
            "0.22.0",
            {"build_number": "1428", "git_sha": "a1b2c3d", "dirty": True},
            "",
        )
        self.assertEqual(text, "0.22.0 (1428 · a1b2c3d+)")


class VariantValidationTests(unittest.TestCase):
    def test_empty_variant_is_allowed_and_keeps_defaults(self) -> None:
        self.assertEqual(stamp.canonical_variant(""), "")

    def test_safe_variants_are_allowed(self) -> None:
        for value in (".b1", "-b2", "b3", "a.b-c"):
            with self.subTest(value=value):
                self.assertEqual(stamp.canonical_variant(value), value)

    def assert_rejected(self, value: str) -> None:
        with redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as raised:
                stamp.canonical_variant(value)
        self.assertEqual(raised.exception.code, 1)

    def test_unsafe_variants_are_rejected(self) -> None:
        for value in ("bad id", "", " ", ".", "..", "a/b", "b1!", "测"):
            if value == "":
                continue
            with self.subTest(value=value):
                self.assert_rejected(value)


class BuildNumberOverrideTests(unittest.TestCase):
    def test_override_replaces_the_commit_count(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            make_repo(repo)
            info = root / "Info.plist"
            write_info_plist(info)
            subprocess.run(
                [
                    "python3",
                    str(ROOT / "tools/Qualification/"
                        "market_scanner_version_stamp.py"),
                    "stamp",
                    "--repo", str(repo),
                    "--info-plist", str(info),
                    "--build-number", "20260831.1",
                ],
                cwd=ROOT,
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertEqual(read_plist(info)["CFBundleVersion"],
                             "20260831.1")

    def test_override_accepts_only_apple_build_number_forms(self) -> None:
        self.assertEqual(stamp.canonical_build_number("999"), "999")
        self.assertEqual(stamp.canonical_build_number("1.2.3"), "1.2.3")

    def assert_rejected(self, value: str) -> None:
        with redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as raised:
                stamp.canonical_build_number(value)
        self.assertEqual(raised.exception.code, 1)

    def test_override_rejects_malformed_values(self) -> None:
        # "" is the "no override" sentinel, not an error.
        for value in ("1.0-beta", "v1", "1.2.3.4", "-1", " 1"):
            with self.subTest(value=value):
                self.assert_rejected(value)


class VersionStampWriteTests(unittest.TestCase):
    def test_stamp_writes_every_info_plist_key(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            make_repo(repo)
            info = root / "Info.plist"
            settings = root / "Root.plist"
            write_info_plist(info)
            write_settings_plist(settings)

            rc = subprocess.run(
                [
                    "python3",
                    str(ROOT / "tools/Qualification/"
                        "market_scanner_version_stamp.py"),
                    "stamp",
                    "--repo", str(repo),
                    "--info-plist", str(info),
                    "--settings-root-plist", str(settings),
                    "--variant", ".b1",
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            self.assertEqual(rc.returncode, 0, rc.stderr)

            payload = read_plist(info)
            self.assertEqual(payload["CFBundleShortVersionString"], "0.22.0")
            self.assertEqual(payload["CFBundleVersion"], "1")
            self.assertEqual(payload["MSBuildVariant"], ".b1")
            self.assertEqual(len(payload["MSBuildGitSHA"]), 7)
            self.assertTrue(
                re.fullmatch(r"[0-9a-f]{7}\+?", payload["MSBuildGitSHA"]))

            items = read_plist(settings)["PreferenceSpecifiers"]
            printed = rc.stdout.strip().removeprefix("version stamp: ")
            self.assertEqual(items[-1]["DefaultValue"], printed)

    def test_stamp_targets_settings_item_by_key_not_index(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            make_repo(repo)
            info = root / "Info.plist"
            settings = root / "Root.plist"
            write_info_plist(info)
            write_settings_plist(settings, decoy_first=True)

            subprocess.run(
                [
                    "python3",
                    str(ROOT / "tools/Qualification/"
                        "market_scanner_version_stamp.py"),
                    "stamp",
                    "--repo", str(repo),
                    "--info-plist", str(info),
                    "--settings-root-plist", str(settings),
                ],
                cwd=ROOT,
                check=True,
                capture_output=True,
                text=True,
            )
            items = read_plist(settings)["PreferenceSpecifiers"]
            self.assertEqual(items[0].get("DefaultValue"), None)
            self.assertIn("(", items[1]["DefaultValue"])

    def test_stamp_keeps_existing_build_number_when_git_is_absent(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "not-a-repo"
            repo.mkdir()
            info = root / "Info.plist"
            write_info_plist(info, build_number="77")

            rc = subprocess.run(
                [
                    "python3",
                    str(ROOT / "tools/Qualification/"
                        "market_scanner_version_stamp.py"),
                    "stamp",
                    "--repo", str(repo),
                    "--info-plist", str(info),
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            self.assertEqual(rc.returncode, 0, rc.stderr)
            payload = read_plist(info)
            self.assertEqual(payload["CFBundleVersion"], "77")
            self.assertEqual(payload["MSBuildGitSHA"], stamp.UNKNOWN_SHA)
            self.assertIn("warning", rc.stderr)

    def test_stamp_fails_closed_on_missing_info_plist(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            make_repo(repo)
            rc = subprocess.run(
                [
                    "python3",
                    str(ROOT / "tools/Qualification/"
                        "market_scanner_version_stamp.py"),
                    "stamp",
                    "--repo", str(repo),
                    "--info-plist", str(root / "missing.plist"),
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            self.assertEqual(rc.returncode, 1)
            self.assertIn("missing", rc.stderr)

    def test_stamp_fails_closed_on_unsafe_variant(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            make_repo(repo)
            info = root / "Info.plist"
            write_info_plist(info)
            rc = subprocess.run(
                [
                    "python3",
                    str(ROOT / "tools/Qualification/"
                        "market_scanner_version_stamp.py"),
                    "stamp",
                    "--repo", str(repo),
                    "--info-plist", str(info),
                    "--variant", "bad id",
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            self.assertEqual(rc.returncode, 1)
            self.assertIn("variant", rc.stderr)


class XcodeWiringTests(unittest.TestCase):
    def test_project_declares_empty_variant_defaults(self) -> None:
        project = PBXPROJ.read_text(encoding="utf-8")
        # The single input is empty by default, so the derived suffixes and
        # therefore the bundle identifier stay byte-identical to the
        # pre-change defaults.
        self.assertIn('MS_BUILD_VARIANT = "";', project)
        self.assertIn('MS_BUILD_NUMBER = "";', project)
        self.assertIn('MS_BUNDLE_ID_SUFFIX = "$(MS_BUILD_VARIANT)";', project)
        self.assertIn('MS_DISPLAY_NAME_SUFFIX = "$(MS_BUILD_VARIANT)";',
                      project)
        self.assertIn(
            'PRODUCT_BUNDLE_IDENTIFIER = '
            '"com.xiehaotian.marketscanner.dev$(MS_BUNDLE_ID_SUFFIX)";',
            project,
        )

    def test_variant_defaults_are_declared_for_both_configurations(
        self,
    ) -> None:
        project = PBXPROJ.read_text(encoding="utf-8")
        for configuration_id in ("4EE015D7259A2AF0008CCE65",
                                 "4EE015D8259A2AF0008CCE65"):
            block = project.split(
                "%s /* " % configuration_id)[1].split("};")[0]
            for setting in (
                "MS_BUILD_NUMBER",
                "MS_BUILD_VARIANT",
                "MS_BUNDLE_ID_SUFFIX",
                "MS_DISPLAY_NAME_SUFFIX",
            ):
                with self.subTest(configuration=configuration_id,
                                  setting=setting):
                    self.assertIn(setting, block)

    def test_info_plist_display_name_uses_variant_suffix(self) -> None:
        payload = read_plist(INFO_PLIST)
        self.assertEqual(
            payload["CFBundleDisplayName"],
            "RTAB-Map$(MS_DISPLAY_NAME_SUFFIX)",
        )

    def test_version_stamp_phase_runs_after_resources(self) -> None:
        project = PBXPROJ.read_text(encoding="utf-8")
        target = project.split(
            "%s /* RTABMapApp */ = {" % TARGET_ID)[1].split(
            "/* End PBXNativeTarget")[0]
        phases = re.search(r"buildPhases = \((.*?)\);", target, re.S)
        self.assertIsNotNone(phases)
        order = re.findall(r"/\* (.+?) \*/", phases.group(1))  # type: ignore[union-attr]
        self.assertLess(order.index("Resources"),
                        order.index("MarketScanner Version Stamp"))
        self.assertLess(order.index("MarketScanner Version Stamp"),
                        order.index("MarketScanner Build Identity"))

    def test_no_phase_can_rewrite_the_stamp_before_signing(self) -> None:
        # The stamp must be the last thing that touches Info.plist and
        # Settings.bundle before Xcode's implicit code signing. The build
        # identity phase only reads them, so anything inserted after it --
        # or between the stamp and code signing -- would leave a plist that
        # no longer matches its signature.
        project = PBXPROJ.read_text(encoding="utf-8")
        target = project.split(
            "%s /* RTABMapApp */ = {" % TARGET_ID)[1].split(
            "/* End PBXNativeTarget")[0]
        phases = re.search(r"buildPhases = \((.*?)\);", target, re.S)
        self.assertIsNotNone(phases)
        order = re.findall(r"/\* (.+?) \*/", phases.group(1))  # type: ignore[union-attr]
        self.assertEqual(order[-2:],
                         ["MarketScanner Version Stamp",
                          "MarketScanner Build Identity"])

    def test_version_stamp_script_writes_the_built_product(self) -> None:
        project = PBXPROJ.read_text(encoding="utf-8")
        phase = project.split(
            "%s /* MarketScanner Version Stamp */ = {" % (
                VERSION_STAMP_PHASE,))[1].split("};")[0]
        self.assertIn("$TARGET_BUILD_DIR/$INFOPLIST_PATH", phase)
        self.assertIn("market_scanner_version_stamp.py", phase)
        self.assertIn("MS_BUILD_VARIANT", phase)
        self.assertIn("MS_BUILD_NUMBER", phase)
        # Writing into ${SRCROOT} would dirty the tracked tree and can trip
        # the clean-tree gate enforced by the build-identity phase.
        self.assertNotIn("${SRCROOT}/Settings.bundle", phase)

    def test_build_script_passes_the_variant_through(self) -> None:
        # releases/ holds local build artifacts and is not tracked, so a
        # clean checkout has no script to inspect. Skip rather than fail:
        # the contract is still checked on every machine that builds ipas.
        if not BUILD_SCRIPT.is_file():
            self.skipTest("%s is untracked and absent from this checkout"
                          % BUILD_SCRIPT.relative_to(ROOT))
        script = BUILD_SCRIPT.read_text(encoding="utf-8")
        self.assertIn("MS_BUILD_VARIANT=", script)
        self.assertIn('VARIANT="${2:-}"', script)


if __name__ == "__main__":
    unittest.main()

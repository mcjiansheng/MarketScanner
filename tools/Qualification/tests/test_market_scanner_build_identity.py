from __future__ import annotations

from contextlib import redirect_stderr
import copy
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

from tools.Qualification import market_scanner_build_identity as identity


ROOT = Path(__file__).resolve().parents[3]


def valid_governance() -> dict[str, str]:
    return {
        "wave": "mobile-only-v1-release-candidate-blocker-closeout",
        "branch": "fix.native-multilink-epoch-bridge",
        "base_branch": "mobile-only-v1r5-field-qualification-integrity-scale-closeout",
        "base_sha": "8" * 40,
        "implementation_sha": "<CODE_CONTRACT_TEST_BUILD_SHA>",
        "validation_sha": "<EVIDENCE_DOCS_SHA>",
    }


def valid_embedded_identity() -> dict[str, object]:
    return {
        "format": identity.FORMAT,
        "version": identity.VERSION,
        "app_git_sha": "a" * 40,
        "native_core_sha256": "b" * 64,
        "build_configuration": "release",
        "working_tree_state": "clean",
        "production_eligible": True,
        "source_ref": "fix/native-multilink-epoch-bridge",
        "source_patch_sha256": identity.EMPTY_PATCH_SHA256,
        **valid_governance(),
    }


class MarketScannerBuildIdentityTests(unittest.TestCase):
    def assert_rejected(self, callback) -> None:
        with redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as raised:
                callback()
        self.assertEqual(raised.exception.code, 1)

    def make_identity_repo(self, root: Path) -> None:
        native = root / "core/MarketScannerFactorGraph"
        native.mkdir(parents=True)
        (native / "market_scanner_factor_graph.cpp").write_text(
            "int market_scanner_test = 1;\n", encoding="utf-8")
        (native / "market_scanner_factor_graph.h").write_text(
            "#pragma once\n", encoding="utf-8")
        governance = root / ".github/marketscanner-repair-v2-wave.json"
        governance.parent.mkdir(parents=True)
        governance.write_text(
            json.dumps(valid_governance()) + "\n",
            encoding="utf-8",
        )
        subprocess.run(["git", "init", "-q"], cwd=root, check=True)
        subprocess.run(
            ["git", "config", "user.email", "identity-test@example.invalid"],
            cwd=root,
            check=True,
        )
        subprocess.run(
            ["git", "config", "user.name", "Identity Test"],
            cwd=root,
            check=True,
        )
        subprocess.run(["git", "add", "."], cwd=root, check=True)
        subprocess.run(
            ["git", "commit", "-q", "-m", "identity fixture"],
            cwd=root,
            check=True,
        )

    def test_current_release_candidate_governance_is_accepted_without_v1r4_prefix(self) -> None:
        descriptor = identity.governance_descriptor(str(ROOT))
        self.assertEqual(
            descriptor["wave"],
            "mobile-only-v1-release-candidate-blocker-closeout",
        )
        self.assertFalse(descriptor["wave"].startswith("mobile-only-v1r4-"))
        self.assertEqual(set(descriptor), identity.GOVERNANCE_KEYS)

    def test_governance_schema_and_safe_names_fail_closed(self) -> None:
        for field, bad_value in (
            ("wave", ""),
            ("wave", "mobile-only/v1"),
            ("branch", "Mobile-Only-RC"),
            ("branch", ".hidden"),
            ("base_branch", "../base"),
            ("base_branch", "base branch"),
        ):
            descriptor = valid_governance()
            descriptor[field] = bad_value
            with self.subTest(field=field, bad_value=bad_value):
                self.assert_rejected(
                    lambda descriptor=descriptor:
                        identity.validate_governance_descriptor(descriptor)
                )

        missing = valid_governance()
        del missing["branch"]
        self.assert_rejected(
            lambda: identity.validate_governance_descriptor(missing)
        )
        extra = valid_governance()
        extra["unexpected"] = "value"
        self.assert_rejected(
            lambda: identity.validate_governance_descriptor(extra)
        )

    def test_governance_sha_fields_allow_only_exact_contract_values(self) -> None:
        bound = valid_governance()
        bound["implementation_sha"] = "c" * 40
        bound["validation_sha"] = "d" * 40
        self.assertEqual(
            identity.validate_governance_descriptor(bound), bound
        )

        for field, bad_value in (
            ("base_sha", "A" * 40),
            ("base_sha", "a" * 39),
            ("implementation_sha", "<UNRECOGNIZED_SHA>"),
            ("implementation_sha", "g" * 40),
            ("validation_sha", ""),
            ("validation_sha", "e" * 39),
        ):
            descriptor = valid_governance()
            descriptor[field] = bad_value
            with self.subTest(field=field, bad_value=bad_value):
                self.assert_rejected(
                    lambda descriptor=descriptor:
                        identity.validate_governance_descriptor(descriptor)
                )

    def test_embedded_identity_reuses_the_governance_contract(self) -> None:
        valid = valid_embedded_identity()
        identity.validate_fields(valid)

        mutations = {
            "wave": "unsafe/wave",
            "branch": "",
            "base_branch": "../base",
            "base_sha": "F" * 40,
            "implementation_sha": "not-a-binding",
            "validation_sha": "f" * 39,
            "app_git_sha": "a" * 39,
            "native_core_sha256": "B" * 64,
            "build_configuration": "profile",
            "working_tree_state": "unknown",
            "production_eligible": False,
            "source_ref": "unsafe ref",
            "source_patch_sha256": "B" * 64,
        }
        for field, bad_value in mutations.items():
            malformed = copy.deepcopy(valid)
            malformed[field] = bad_value
            with self.subTest(field=field):
                self.assert_rejected(
                    lambda malformed=malformed:
                        identity.validate_fields(malformed)
                )

        unknown = copy.deepcopy(valid)
        unknown["unexpected"] = True
        self.assert_rejected(lambda: identity.validate_fields(unknown))

    def test_debug_and_release_identity_eligibility_is_explicit(self) -> None:
        release = valid_embedded_identity()
        identity.validate_fields(release)

        debug_clean = copy.deepcopy(release)
        debug_clean["build_configuration"] = "debug"
        debug_clean["production_eligible"] = False
        identity.validate_fields(debug_clean)

        debug_dirty = copy.deepcopy(debug_clean)
        debug_dirty["working_tree_state"] = "dirty"
        debug_dirty["source_patch_sha256"] = "c" * 64
        identity.validate_fields(debug_dirty)

        release_dirty = copy.deepcopy(release)
        release_dirty["working_tree_state"] = "dirty"
        release_dirty["production_eligible"] = False
        self.assert_rejected(lambda: identity.validate_fields(release_dirty))

        inconsistent = copy.deepcopy(debug_dirty)
        inconsistent["production_eligible"] = True
        self.assert_rejected(lambda: identity.validate_fields(inconsistent))

        numeric_boolean = copy.deepcopy(debug_dirty)
        numeric_boolean["production_eligible"] = 0
        self.assert_rejected(lambda: identity.validate_fields(numeric_boolean))

    def test_dirty_debug_is_traceable_while_release_remains_clean_only(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            self.make_identity_repo(repo)

            release = identity.build_identity(
                str(repo), allow_dirty=False, build_configuration="Release")
            self.assertEqual(release["build_configuration"], "release")
            self.assertEqual(release["working_tree_state"], "clean")
            self.assertIs(release["production_eligible"], True)
            self.assertEqual(
                release["source_patch_sha256"], identity.EMPTY_PATCH_SHA256)

            native = (
                repo
                / "core/MarketScannerFactorGraph/market_scanner_factor_graph.cpp"
            )
            native.write_text(
                "int market_scanner_test = 2;\n", encoding="utf-8")
            debug = identity.build_identity(
                str(repo), allow_dirty=True, build_configuration="Debug")
            self.assertEqual(debug["build_configuration"], "debug")
            self.assertEqual(debug["working_tree_state"], "dirty")
            self.assertIs(debug["production_eligible"], False)
            self.assertNotEqual(
                debug["source_patch_sha256"], identity.EMPTY_PATCH_SHA256)
            first_patch_digest = debug["source_patch_sha256"]
            native.write_text(
                "int market_scanner_test = 3;\n", encoding="utf-8")
            changed_debug = identity.build_identity(
                str(repo), allow_dirty=True, build_configuration="Debug")
            self.assertNotEqual(
                changed_debug["source_patch_sha256"], first_patch_digest)
            self.assert_rejected(
                lambda: identity.build_identity(
                    str(repo),
                    allow_dirty=True,
                    build_configuration="Release",
                )
            )

    def test_xcode_default_launch_uses_release_and_debug_emits_identity(
        self,
    ) -> None:
        scheme_path = (
            ROOT
            / "app/ios/RTABMapApp.xcodeproj/xcshareddata/xcschemes/RTABMapApp.xcscheme"
        )
        scheme = ET.parse(scheme_path).getroot()
        for action in ("TestAction", "AnalyzeAction"):
            node = scheme.find(action)
            self.assertIsNotNone(node)
            self.assertEqual(node.attrib.get("buildConfiguration"), "Debug")
        for action in ("LaunchAction", "ProfileAction", "ArchiveAction"):
            node = scheme.find(action)
            self.assertIsNotNone(node)
            self.assertEqual(node.attrib.get("buildConfiguration"), "Release")

        project = (
            ROOT / "app/ios/RTABMapApp.xcodeproj/project.pbxproj"
        ).read_text(encoding="utf-8")
        self.assertIn('if [ \\"$CONFIGURATION\\" = \\"Debug\\" ]', project)
        self.assertNotIn('rm -f \\"$OUT\\"', project)
        self.assertIn(
            '--configuration \\"$CONFIGURATION\\" --allow-dirty',
            project,
        )
        self.assertIn(
            'verify --repo \\"$REPO_ROOT\\" --identity \\"$OUT\\" '
            '--configuration \\"$CONFIGURATION\\"',
            project,
        )

    def test_xcode_qualified_device_launch_uses_release_identity(self) -> None:
        scheme_path = (
            ROOT
            / "app/ios/RTABMapApp.xcodeproj/xcshareddata/xcschemes/"
            "RTABMapApp-QualifiedDevice.xcscheme"
        )
        scheme = ET.parse(scheme_path).getroot()

        build_entry = scheme.find("./BuildAction/BuildActionEntries/BuildActionEntry")
        self.assertIsNotNone(build_entry)
        self.assertEqual(build_entry.attrib.get("buildForRunning"), "YES")

        launch = scheme.find("LaunchAction")
        self.assertIsNotNone(launch)
        self.assertEqual(launch.attrib.get("buildConfiguration"), "Release")

        runnable = launch.find("./BuildableProductRunnable/BuildableReference")
        self.assertIsNotNone(runnable)
        self.assertEqual(
            runnable.attrib.get("BlueprintIdentifier"),
            "4EE015C1259A2AF0008CCE65",
        )
        self.assertEqual(runnable.attrib.get("BuildableName"), "RTABMapApp.app")
        self.assertEqual(runnable.attrib.get("BlueprintName"), "RTABMapApp")
        self.assertEqual(
            runnable.attrib.get("ReferencedContainer"),
            "container:RTABMapApp.xcodeproj",
        )

        for action in ("ProfileAction", "ArchiveAction"):
            node = scheme.find(action)
            self.assertIsNotNone(node)
            self.assertEqual(node.attrib.get("buildConfiguration"), "Release")

        project = (
            ROOT / "app/ios/RTABMapApp.xcodeproj/project.pbxproj"
        ).read_text(encoding="utf-8")
        self.assertIn(
            "market_scanner_build_identity.py\\\" emit --repo",
            project,
        )
        self.assertIn(
            '--configuration \\"$CONFIGURATION\\"',
            project,
        )

    @unittest.skipUnless(shutil.which("xcrun"), "Swift host requires Xcode")
    def test_swift_host_matches_governance_and_pre_rename_freeze_contracts(self) -> None:
        xcrun = shutil.which("xcrun")
        assert xcrun is not None
        sources = [
            ROOT / "app/ios/RTABMapApp/StrictJSONScalar.swift",
            ROOT / "app/ios/RTABMapApp/StrictJSONKeyUniquenessValidator.swift",
            ROOT / "app/ios/RTABMapApp/StrictJSONDocumentParser.swift",
            ROOT / "app/ios/RTABMapApp/MobileMapImport/CanonicalJSONEncoder.swift",
            ROOT / "app/ios/RTABMapApp/MobileOnlyWorkflow/MobileOnlyWorkflowError.swift",
            ROOT / "app/ios/RTABMapApp/MobileOnlyWorkflow/MobileBuildIdentity.swift",
            ROOT / "app/ios/RTABMapApp/MobilePostProcessing/ImmutableDirectoryPublication.swift",
            ROOT / "app/ios/RTABMapApp/MobileOnlyWorkflow/MobileResultLibrary.swift",
            ROOT / "app/ios/RTABMapApp/MobilePostProcessing/SessionSnapshotTransaction.swift",
            Path(__file__).with_name("swift") / "main.swift",
        ]
        with tempfile.TemporaryDirectory() as temporary:
            executable = Path(temporary) / "market-scanner-governance-tests"
            environment = os.environ.copy()
            environment["CLANG_MODULE_CACHE_PATH"] = str(
                Path(temporary) / "clang-cache"
            )
            environment["SWIFT_MODULECACHE_PATH"] = str(
                Path(temporary) / "swift-cache"
            )
            compile_result = subprocess.run(
                [xcrun, "swiftc", *map(str, sources), "-o", str(executable)],
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            )
            self.assertEqual(
                compile_result.returncode, 0, compile_result.stderr
            )
            run_result = subprocess.run(
                [str(executable)],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(run_result.returncode, 0, run_result.stderr)
            self.assertIn(
                "Swift build identity governance contract passed",
                run_result.stdout,
            )
            self.assertIn(
                "Swift result macOS-14 publication and recovery contract passed",
                run_result.stdout,
            )
            self.assertIn(
                "Swift immutable-directory post-freeze replacement contract passed",
                run_result.stdout,
            )
            self.assertIn(
                "Swift result process-lock pathname binding contract passed",
                run_result.stdout,
            )
            self.assertIn(
                "Swift result final process-lock validation contract passed",
                run_result.stdout,
            )
            self.assertIn(
                "Swift snapshot process-lock pathname binding contract passed",
                run_result.stdout,
            )
            self.assertIn(
                "Swift snapshot final process-lock validation contract passed",
                run_result.stdout,
            )
            self.assertIn(
                "Swift terminal-state durability matrix passed",
                run_result.stdout,
            )
            self.assertIn(
                "Swift terminal-intent conflict matrix passed",
                run_result.stdout,
            )


if __name__ == "__main__":
    unittest.main()

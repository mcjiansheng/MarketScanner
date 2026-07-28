from __future__ import annotations

import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile
from unittest import mock

from tools.SupermarketMapStudio.release_manifest import generate
from tools.SupermarketMapStudio.ios_dependency_manifest import generate as generate_ios, verify as verify_ios
from tools.SupermarketMapStudio.package_release import (
    PackagingError,
    create_package,
)
STUDIO_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(STUDIO_DIR))
from tools.SupermarketMapStudio.server import operator_package_diagnostic  # noqa: E402


class ReleaseManifestTests(unittest.TestCase):
    def test_ios_gtsam_build_uses_cxx17_for_current_boost_headers(self) -> None:
        install_script = (
            Path(__file__).resolve().parents[3]
            / "app"
            / "ios"
            / "RTABMapApp"
            / "install_deps.sh"
        ).read_text(encoding="utf-8")
        self.assertIn("-DCMAKE_CXX_STANDARD=17", install_script)
        self.assertIn("-DGTSAM_CXX_STANDARD=17", install_script)
        self.assertIn("-DCMAKE_CXX_STANDARD_REQUIRED=ON", install_script)
        self.assertIn('"-DCMAKE_CXX_FLAGS=-include TargetConditionals.h"', install_script)

    def test_manifest_hashes_artifacts_and_is_reproducible_for_fixed_inputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            artifact = root / "tool.bin"
            artifact.write_bytes(b"release-binary")
            policy = root / "policy.json"
            policy.write_text(
                json.dumps({"format": "MarketScannerDependencyPolicy", "version": 1}),
                encoding="utf-8",
            )
            one = generate(
                output=root / "one.json", git_sha="a" * 40, target_platform="macos",
                artifacts=[artifact], dependency_policy=policy,
                build_time_utc="2026-07-28T00:00:00+00:00",
            )
            two = generate(
                output=root / "two.json", git_sha="a" * 40, target_platform="macos",
                artifacts=[artifact], dependency_policy=policy,
                build_time_utc="2026-07-28T00:00:00+00:00",
            )
            self.assertEqual(one, two)
            self.assertEqual(one["artifacts"][0]["sha256"], hashlib.sha256(b"release-binary").hexdigest())

    def test_invalid_sha_and_missing_artifact_fail_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            policy = root / "policy.json"
            policy.write_text('{"format":"MarketScannerDependencyPolicy","version":1}', encoding="utf-8")
            with self.assertRaises(ValueError):
                generate(output=root / "out", git_sha="bad", target_platform="macos", artifacts=[root / "missing"], dependency_policy=policy)
            with self.assertRaises(ValueError):
                generate(output=root / "out", git_sha="a" * 40, target_platform="macos", artifacts=[root / "missing"], dependency_policy=policy)

    def test_ios_dependency_manifest_detects_same_size_tampering(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            policy = json.loads(
                (Path(__file__).parents[1] / "release_dependencies.json").read_text(encoding="utf-8")
            )
            for relative in policy["ios"]["required_artifacts"]:
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"abcd")
            manifest = root / "ios-dependency-manifest.json"
            generate_ios(root, manifest, "a" * 40)
            verify_ios(root, manifest)
            changed = root / policy["ios"]["required_artifacts"][0]
            changed.write_bytes(b"wxyz")
            with self.assertRaisesRegex(ValueError, "differs"):
                verify_ios(root, manifest)

    def test_operator_package_is_hash_bound_and_no_overwrite(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            reprocess = root / "rtabmap-reprocess"
            factor = root / "rtabmap-prior-map-factor-graph"
            version_line = f"#!/bin/sh\necho marketscanner_git_sha={'d' * 40}\n"
            reprocess.write_text(version_line, encoding="utf-8")
            factor.write_text(version_line, encoding="utf-8")
            reprocess.chmod(0o755)
            factor.chmod(0o755)
            policy = root / "policy.json"
            policy.write_text(
                json.dumps({"format": "MarketScannerDependencyPolicy", "version": 1}),
                encoding="utf-8",
            )
            release_path = root / "release.json"
            generate(
                output=release_path,
                git_sha="d" * 40,
                target_platform="macos",
                artifacts=[reprocess, factor],
                dependency_policy=policy,
                build_time_utc="2026-07-28T00:00:00+00:00",
            )
            archive = root / "MapStudio-macos.zip"
            with (
                mock.patch(
                    "tools.SupermarketMapStudio.package_release.current_source_git_sha",
                    return_value="d" * 40,
                ),
                mock.patch(
                    "tools.SupermarketMapStudio.package_release.source_tree_is_clean",
                    return_value=True,
                ),
            ):
                package = create_package(
                    platform_name="macos",
                    output=archive,
                    release_manifest=release_path,
                    reprocess_binary=reprocess,
                    factor_binary=factor,
                )
            self.assertEqual(package["gitSha"], "d" * 40)
            self.assertRegex(package["archiveSha256"], r"^[0-9a-f]{64}$")
            extracted = root / "extracted"
            with zipfile.ZipFile(archive) as bundle:
                bundle.extractall(extracted)
            self.assertTrue(operator_package_diagnostic(extracted)["ok"])
            installed_server = extracted / "tools/SupermarketMapStudio/server.py"
            contents = installed_server.read_bytes()
            installed_server.write_bytes(bytes([contents[0] ^ 0x01]) + contents[1:])
            self.assertFalse(operator_package_diagnostic(extracted)["ok"])
            with (
                mock.patch(
                    "tools.SupermarketMapStudio.package_release.current_source_git_sha",
                    return_value="d" * 40,
                ),
                mock.patch(
                    "tools.SupermarketMapStudio.package_release.source_tree_is_clean",
                    return_value=True,
                ),
            ):
                with self.assertRaisesRegex(PackagingError, "already exists"):
                    create_package(
                        platform_name="macos",
                        output=archive,
                        release_manifest=release_path,
                        reprocess_binary=reprocess,
                        factor_binary=factor,
                    )
                reprocess.write_text(version_line.replace("echo", "Echo"), encoding="utf-8")
                with self.assertRaisesRegex(PackagingError, "hash-bound"):
                    create_package(
                        platform_name="macos",
                        output=root / "tampered.zip",
                        release_manifest=release_path,
                        reprocess_binary=reprocess,
                        factor_binary=factor,
                    )


if __name__ == "__main__":
    unittest.main()

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
import zipfile
from types import SimpleNamespace
from unittest import mock

from tools.SupermarketMapStudio.release_manifest import generate
from tools.SupermarketMapStudio.ios_dependency_manifest import generate as generate_ios, verify as verify_ios
from tools.SupermarketMapStudio.package_release import (
    PackagingError,
    create_package,
)
STUDIO_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(STUDIO_DIR))
import tools.SupermarketMapStudio.server as server_module  # noqa: E402
from tools.SupermarketMapStudio.server import operator_package_diagnostic  # noqa: E402


def _macho_archive(platform_id: int, cpu_type: int = 0x0100000C) -> bytes:
    command = struct.pack("<IIIIII", 0x32, 24, platform_id, 0x000C0000, 0, 0)
    obj = struct.pack(
        "<IiiIIIII", 0xFEEDFACF, cpu_type, 0, 1, 1, len(command), 0, 0
    ) + command
    header = b"".join(
        (
            b"fixture.o/".ljust(16),
            b"0".ljust(12),
            b"0".ljust(6),
            b"0".ljust(6),
            b"100644".ljust(8),
            str(len(obj)).encode("ascii").ljust(10),
            b"`\n",
        )
    )
    return b"!<arch>\n" + header + obj + (b"\n" if len(obj) % 2 else b"")


def _write_ios_dependency_fixture(root: Path, platform_id: int) -> dict[str, object]:
    policy = json.loads(
        (Path(__file__).parents[1] / "release_dependencies.json").read_text(
            encoding="utf-8"
        )
    )
    binary = _macho_archive(platform_id)
    platform_artifacts = set(policy["ios"]["platform_validated_artifacts"])
    for relative in policy["ios"]["required_artifacts"]:
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(binary if relative in platform_artifacts else b"fixture")
    return policy


class ReleaseManifestTests(unittest.TestCase):
    def test_production_release_identity_ignores_external_override(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)

            def release_value(product_version: str) -> dict[str, object]:
                value: dict[str, object] = {
                    "format": "MarketScannerReleaseManifest",
                    "version": 2,
                    "git_sha": "d" * 40,
                    "product_version": product_version,
                    "factor_graph_quality_policy_sha256": "e" * 64,
                }
                value["manifest_body_sha256"] = hashlib.sha256(
                    json.dumps(
                        value, sort_keys=True, separators=(",", ":")
                    ).encode("utf-8")
                ).hexdigest()
                return value

            packaged_release = root / "release-manifest.json"
            packaged_release.write_text(
                json.dumps(release_value("package-A")), encoding="utf-8"
            )
            packaged_sha = hashlib.sha256(packaged_release.read_bytes()).hexdigest()
            (root / "package-manifest.json").write_text(
                json.dumps(
                    {
                        "format": "MarketScannerMapStudioOperatorPackage",
                        "version": 1,
                        "gitSha": "d" * 40,
                        "releaseManifestSha256": packaged_sha,
                    }
                ),
                encoding="utf-8",
            )
            override = root / "external-release.json"
            override.write_text(
                json.dumps(release_value("external-B")), encoding="utf-8"
            )
            app_dir = root / "tools" / "SupermarketMapStudio"
            with (
                mock.patch.object(server_module, "APP_DIR", app_dir),
                mock.patch.dict(
                    server_module.os.environ,
                    {"MARKETSCANNER_RELEASE_MANIFEST": str(override)},
                ),
            ):
                identity = server_module.runtime_release_identity("production")
            self.assertEqual(identity["product_version"], "package-A")
            self.assertEqual(identity["release_manifest_sha256"], packaged_sha)

    def test_package_json_stable_read_rejects_symlink_and_same_size_swap(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / "release-manifest.json"
            path.write_text('{"value":"aaaa"}', encoding="utf-8")
            link = root / "release-link.json"
            link.symlink_to(path)
            with self.assertRaisesRegex(ValueError, "unsafe or oversized"):
                server_module._stable_json_file(link)

            replacement = root / "replacement.json"
            replacement.write_text('{"value":"bbbb"}', encoding="utf-8")
            self.assertEqual(path.stat().st_size, replacement.stat().st_size)
            real_read = server_module.os.read
            replaced = False

            def replace_after_open(descriptor: int, count: int) -> bytes:
                nonlocal replaced
                if not replaced:
                    replaced = True
                    replacement.replace(path)
                return real_read(descriptor, count)

            with mock.patch.object(
                server_module.os, "read", side_effect=replace_after_open
            ):
                with self.assertRaisesRegex(ValueError, "changed during read"):
                    server_module._stable_json_file(path)

    def test_windows_native_ci_pins_dependency_archive_and_builds_release_tools(self) -> None:
        repository = Path(__file__).resolve().parents[3]
        dependency_action = (repository / ".github/actions/install-windows-deps/action.yml").read_text(
            encoding="utf-8"
        )
        workflow = (repository / ".github/workflows/marketscanner-repair-v2.yml").read_text(
            encoding="utf-8"
        )
        expected_sha256 = "8093a0fe6eb424594514eac166a6ede65b798500031093eaff01fd5e2ee8bf50"
        self.assertIn(f'$expectedSha256 = "{expected_sha256}"', dependency_action)
        self.assertIn("Get-FileHash -LiteralPath $archivePath -Algorithm SHA256", dependency_action)
        self.assertIn("for ($attempt = 1; $attempt -le 3; $attempt++)", dependency_action)
        self.assertIn("windows-native-clean-build:", workflow)
        self.assertIn("cmake --fresh --preset marketscanner-windows-release", workflow)
        self.assertIn("cmake --build --preset marketscanner-windows-release --parallel 2", workflow)
        self.assertIn("marketscanner-windows-release-manifest.json", workflow)
        self.assertIn("rtabmap-prior-map-factor-graph.exe", workflow)

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

    def test_ios_liblas_build_pins_geotiff_optional_revision_and_policy_floor(self) -> None:
        install_script = (
            Path(__file__).resolve().parents[3]
            / "app"
            / "ios"
            / "RTABMapApp"
            / "install_deps.sh"
        ).read_text(encoding="utf-8")
        liblas_block = install_script.split("# LAS\nif [ ! -e $prefix/include/liblas ]", 1)[1]
        self.assertIn("33097f17e27b853ac7b9651025a70354ffb10cfc", liblas_block)
        self.assertIn("-DCMAKE_POLICY_VERSION_MINIMUM=3.5", liblas_block)
        self.assertIn("-DWITH_GEOTIFF=OFF", liblas_block)
        self.assertNotIn("--branch 1.8.1", liblas_block)

    def test_ios_dependency_network_fetches_are_bounded_and_atomic(self) -> None:
        install_script = (
            Path(__file__).resolve().parents[3]
            / "app"
            / "ios"
            / "RTABMapApp"
            / "install_deps.sh"
        ).read_text(encoding="utf-8")
        active_lines = [
            line.strip()
            for line in install_script.splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        ]
        self.assertIn("clone_with_retry()", active_lines)
        self.assertIn("download_with_retry()", active_lines)
        self.assertEqual([line for line in active_lines if "git clone" in line], ['if git clone "$@" "$temporary/repository"'])
        self.assertEqual([line for line in active_lines if line.startswith("curl ")], ["curl --fail --location --retry 3 --retry-all-errors --retry-delay 5 \\"])
        self.assertIn('temporary=$(mktemp -d "$work_root/.clone-${destination}.XXXXXX")', active_lines)
        self.assertIn('local temporary="${output}.partial"', active_lines)
        self.assertEqual(sum(line.startswith("clone_with_retry ") for line in active_lines), 11)

    def test_ios_full_link_declares_blas_provider_and_preserves_verified_cache(self) -> None:
        repository = Path(__file__).resolve().parents[3]
        project = (repository / "app/ios/RTABMapApp.xcodeproj/project.pbxproj").read_text(
            encoding="utf-8"
        )
        install_script = (repository / "app/ios/RTABMapApp/install_deps.sh").read_text(
            encoding="utf-8"
        )
        workflow = (repository / ".github/workflows/marketscanner-repair-v2.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("Accelerate.framework in Frameworks", project)
        self.assertIn("System/Library/Frameworks/Accelerate.framework", project)
        vtk_block = install_script.split("# VTK", 1)[1].split("# PCL", 1)[0]
        self.assertIn("-DIOS_DEPLOYMENT_TARGET=12.0", vtk_block)
        self.assertIn("uses: actions/cache/restore@v4", workflow)
        self.assertIn("Libraries/iphoneos", workflow)
        self.assertIn("Libraries/iphonesimulator", workflow)
        save_position = workflow.index("uses: actions/cache/save@v4")
        link_position = workflow.index("- name: Build unsigned generic arm64 iOS app")
        self.assertLess(save_position, link_position)

    def test_ios_native_build_and_link_contract_is_platform_scoped(self) -> None:
        repository = Path(__file__).resolve().parents[3]
        project = (repository / "app/ios/RTABMapApp.xcodeproj/project.pbxproj").read_text(
            encoding="utf-8"
        )
        xcconfig = (
            repository
            / "app/ios/RTABMapApp/MarketScannerNativeDependencies.xcconfig"
        ).read_text(encoding="utf-8")
        install_script = (repository / "app/ios/RTABMapApp/install_deps.sh").read_text(
            encoding="utf-8"
        )
        workflow = (repository / ".github/workflows/marketscanner-repair-v2.yml").read_text(
            encoding="utf-8"
        )

        self.assertIn("--platform iphoneos|iphonesimulator", install_script)
        self.assertIn('prefix="$libraries_root/$platform"', install_script)
        self.assertIn('sysroot="$platform"', install_script)
        self.assertIn('vtk_device_architectures="arm64"', install_script)
        self.assertIn('vtk_simulator_architectures="arm64"', install_script)
        self.assertNotIn("sysroot=iphoneos", install_script)

        library_project_lines = [
            line for line in project.splitlines() if "RTABMapApp/Libraries/" in line
        ]
        self.assertTrue(library_project_lines)
        self.assertTrue(
            all("$(PLATFORM_NAME)" in line for line in library_project_lines)
        )
        self.assertNotIn(".a in Frameworks", project)
        self.assertNotIn("vtk.framework in Frameworks", project)
        self.assertEqual(project.count("baseConfigurationReference = 4EA800012F70000700100002"), 2)

        self.assertIn("Libraries/$(PLATFORM_NAME)", xcconfig)
        self.assertIn("ARCHS[sdk=iphonesimulator*] = arm64", xcconfig)
        self.assertIn("-framework vtk", xcconfig)
        self.assertIn("librtabmap_core.a", xcconfig)

        self.assertIn("id: ios_native_iphoneos_cache", workflow)
        self.assertIn("id: ios_native_iphonesimulator_cache", workflow)
        self.assertIn("install_deps.sh --platform iphoneos", workflow)
        self.assertIn("install_deps.sh --platform iphonesimulator", workflow)
        self.assertIn("--platform iphoneos", workflow)
        self.assertIn("--platform iphonesimulator", workflow)
        self.assertNotIn("app/ios/RTABMapApp/Libraries/include", workflow)
        self.assertNotIn("app/ios/RTABMapApp/Libraries/lib\n", workflow)
        self.assertIn("-destination 'generic/platform=iOS Simulator'", workflow)
        self.assertGreaterEqual(
            workflow.count('cmp -s "$RUNNER_TEMP/MarketScanner-Package.resolved"'),
            2,
        )
        self.assertNotIn('cp "$lock_backup" "$lock"', workflow)

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

    def test_repository_dependency_policy_v2_is_release_manifest_compatible(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            artifact = root / "tool.bin"
            artifact.write_bytes(b"release-binary")
            repository_policy = Path(__file__).parents[1] / "release_dependencies.json"
            manifest = generate(
                output=root / "release.json",
                git_sha="a" * 40,
                target_platform="linux",
                artifacts=[artifact],
                dependency_policy=repository_policy,
                build_time_utc="2026-08-07T00:00:00+00:00",
            )
            self.assertEqual(manifest["dependency_policy"]["version"], 2)

    def test_linux_release_preset_builds_the_native_qualification_binary(self):
        repository = Path(__file__).resolve().parents[3]
        presets = json.loads(
            (repository / "CMakePresets.json").read_text(encoding="utf-8")
        )
        linux = next(
            preset
            for preset in presets["buildPresets"]
            if preset["name"] == "marketscanner-linux-release"
        )
        self.assertIn("market_scanner_native_tests", linux["targets"])
        workflow = (
            repository / ".github/workflows/marketscanner-repair-v2.yml"
        ).read_text(encoding="utf-8")
        self.assertIn(
            "build/marketscanner-linux-release/bin/rtabmap-market-scanner-native-tests",
            workflow,
        )

    def test_invalid_sha_and_missing_artifact_fail_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            policy = root / "policy.json"
            policy.write_text('{"format":"MarketScannerDependencyPolicy","version":1}', encoding="utf-8")
            with self.assertRaises(ValueError):
                generate(output=root / "out", git_sha="bad", target_platform="macos", artifacts=[root / "missing"], dependency_policy=policy)
            with self.assertRaises(ValueError):
                generate(output=root / "out", git_sha="a" * 40, target_platform="macos", artifacts=[root / "missing"], dependency_policy=policy)
            artifact = root / "artifact"
            artifact.write_bytes(b"artifact")
            for invalid_value in (True, 2.0, 3):
                with self.subTest(dependency_policy_version=invalid_value):
                    invalid_version = root / "invalid-version.json"
                    invalid_version.write_text(
                        json.dumps(
                            {
                                "format": "MarketScannerDependencyPolicy",
                                "version": invalid_value,
                            }
                        ),
                        encoding="utf-8",
                    )
                    with self.assertRaisesRegex(ValueError, "format/version"):
                        generate(
                            output=root / "out",
                            git_sha="a" * 40,
                            target_platform="macos",
                            artifacts=[artifact],
                            dependency_policy=invalid_version,
                        )

    def test_ios_dependency_manifest_detects_same_size_tampering(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            policy = _write_ios_dependency_fixture(root, platform_id=2)
            manifest = root / "ios-dependency-manifest.json"
            generate_ios(root, manifest, "a" * 40, "iphoneos")
            verify_ios(root, manifest, "iphoneos")
            changed = root / policy["ios"]["required_artifacts"][0]
            contents = changed.read_bytes()
            changed.write_bytes(bytes([contents[0] ^ 1]) + contents[1:])
            with self.assertRaisesRegex(ValueError, "differs"):
                verify_ios(root, manifest, "iphoneos")

    def test_ios_dependency_manifest_rejects_device_archive_for_simulator(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            _write_ios_dependency_fixture(root, platform_id=2)
            with self.assertRaisesRegex(ValueError, "platform mismatch"):
                generate_ios(
                    root,
                    root / "ios-dependency-manifest.json",
                    "a" * 40,
                    "iphonesimulator",
                )

    def test_ios_dependency_manifest_rejects_simulator_archive_for_device(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            _write_ios_dependency_fixture(root, platform_id=7)
            with self.assertRaisesRegex(ValueError, "platform mismatch"):
                generate_ios(
                    root,
                    root / "ios-dependency-manifest.json",
                    "a" * 40,
                    "iphoneos",
                )

    def test_ios_dependency_manifest_requires_platform_field(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            _write_ios_dependency_fixture(root, platform_id=2)
            manifest = root / "ios-dependency-manifest.json"
            payload = generate_ios(root, manifest, "a" * 40, "iphoneos")
            del payload["platform"]
            manifest.write_text(json.dumps(payload), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "platform mismatch"):
                verify_ios(root, manifest, "iphoneos")

    def test_ios_dependency_manifest_malformed_json_fails_with_value_error(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            _write_ios_dependency_fixture(root, platform_id=2)
            manifest = root / "ios-dependency-manifest.json"
            original = generate_ios(root, manifest, "a" * 40, "iphoneos")

            manifest.write_text("[]", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "root must be an object"):
                verify_ios(root, manifest, "iphoneos")

            for malformed_files, expected_message in (
                ([None], "file entry 0 must be an object"),
                (
                    [{"file": "../escape", "bytes": 1, "sha256": "a" * 64}],
                    "outside include/lib",
                ),
                (
                    [{"file": "include/bad", "bytes": "1", "sha256": "a" * 64}],
                    "invalid byte count",
                ),
            ):
                payload = dict(original)
                payload["files"] = malformed_files
                body = {
                    key: value
                    for key, value in payload.items()
                    if key != "manifest_body_sha256"
                }
                payload["manifest_body_sha256"] = hashlib.sha256(
                    json.dumps(body, sort_keys=True, separators=(",", ":")).encode()
                ).hexdigest()
                manifest.write_text(json.dumps(payload), encoding="utf-8")
                with self.subTest(malformed_files=malformed_files):
                    with self.assertRaisesRegex(ValueError, expected_message):
                        verify_ios(root, manifest, "iphoneos")

    def test_ios_dependency_manifest_rejects_unsupported_platform(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            _write_ios_dependency_fixture(root, platform_id=2)
            with self.assertRaisesRegex(ValueError, "unsupported"):
                generate_ios(root, root / "manifest.json", "a" * 40, "watchos")

    def test_ios_dependency_manifest_ci_rejects_legacy_unscoped_prefix(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "Libraries"
            root.mkdir()
            _write_ios_dependency_fixture(root, platform_id=2)
            with self.assertRaisesRegex(ValueError, "platform-scoped"):
                generate_ios(
                    root,
                    root / "ios-dependency-manifest.json",
                    "a" * 40,
                    "iphoneos",
                    ci_mode=True,
                )

    def test_ios_dependency_manifest_ci_accepts_exact_scoped_prefix(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "Libraries" / "iphonesimulator"
            root.mkdir(parents=True)
            _write_ios_dependency_fixture(root, platform_id=7)
            manifest = root / "ios-dependency-manifest.json"
            generate_ios(
                root,
                manifest,
                "a" * 40,
                "iphonesimulator",
                ci_mode=True,
            )
            verify_ios(root, manifest, "iphonesimulator", ci_mode=True)

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
                mock.patch(
                    "tools.SupermarketMapStudio.package_release.subprocess.run",
                    return_value=SimpleNamespace(
                        returncode=0,
                        stdout=f"marketscanner_git_sha={'d' * 40}\n",
                        stderr="",
                    ),
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
                mock.patch(
                    "tools.SupermarketMapStudio.package_release.subprocess.run",
                    return_value=SimpleNamespace(
                        returncode=0,
                        stdout=f"marketscanner_git_sha={'d' * 40}\n",
                        stderr="",
                    ),
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

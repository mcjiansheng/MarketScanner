from __future__ import annotations

import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from tools.SupermarketMapStudio.release_manifest import generate
from tools.SupermarketMapStudio.ios_dependency_manifest import generate as generate_ios, verify as verify_ios


class ReleaseManifestTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()

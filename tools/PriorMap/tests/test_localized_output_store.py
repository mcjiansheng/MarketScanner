from __future__ import annotations

import csv
import json
import tempfile
import unittest
from pathlib import Path

from tools.PriorMap.localized_output_store import (
    LocalizedStoreError,
    LocalizedVersionStore,
    REQUIRED_VERSION_FILES,
)


class LocalizedVersionStoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.output = Path(self.temporary.name) / "output"
        self.store = LocalizedVersionStore(self.output)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_valid_staging(
        self, *, revision: int = 1, state: str = "draft"
    ) -> Path:
        staging = self.store.begin()
        json_payloads: dict[str, object] = {
            "prior_map_manifest.json": {"format": "PriorMap"},
            "source_manifest.json": {"format": "Source"},
            "processing_manifest.json": {"format": "Processing"},
            "online_localization_trace.json": [],
            "optimized_map_trajectory.geojson": {
                "type": "FeatureCollection",
                "features": [],
            },
            "localization_constraints.json": {},
            "localization_report.json": {"publish_state": state},
            "review_items.json": {"items": []},
            "localized_review.json": {},
            "manual_edits.json": {"revision": revision, "events": [], "cursor": 0},
            "localized_price_tags.json": [],
            "localized_price_tags.geojson": {
                "type": "FeatureCollection",
                "features": [],
            },
            "shelf_tag_index.json": {"shelves": {}},
        }
        for name, payload in json_payloads.items():
            (staging / name).write_text(
                json.dumps(payload, sort_keys=True) + "\n", encoding="utf-8"
            )
        with (staging / "localized_price_tags.csv").open(
            "w", encoding="utf-8", newline=""
        ) as handle:
            writer = csv.DictWriter(handle, fieldnames=["tag_id", "approval_status"])
            writer.writeheader()
        (staging / "audit_log.jsonl").write_text(
            '{"event":"test"}\n', encoding="utf-8"
        )
        self.assertEqual(
            set(REQUIRED_VERSION_FILES),
            {path.name for path in staging.iterdir()},
        )
        return staging

    def commit_valid(
        self, *, revision: int = 1, state: str = "draft", update_current: bool = True
    ):
        staging = self.write_valid_staging(revision=revision, state=state)
        manifest = self.store.validate_staging(staging, parent_version=None)
        return self.store.commit(staging, manifest, update_current=update_current)

    def test_failed_validation_leaves_current_unchanged(self) -> None:
        first = self.commit_valid()
        staging = self.write_valid_staging(revision=2)
        (staging / "localized_review.json").unlink()
        with self.assertRaises(LocalizedStoreError):
            self.store.validate_staging(staging, parent_version=first.version_id)
        self.store.abort(staging)
        current = self.store.current()
        self.assertIsNotNone(current)
        assert current is not None
        self.assertEqual(current.version_id, first.version_id)
        self.assertTrue(first.version_dir.is_dir())

    def test_new_version_is_immutable_and_pointer_switch_is_atomic(self) -> None:
        first = self.commit_valid()
        first_report = (first.version_dir / "localization_report.json").read_bytes()
        staging = self.write_valid_staging(revision=2, state="review")
        manifest = self.store.validate_staging(
            staging, parent_version=first.version_id
        )
        second = self.store.commit(staging, manifest, update_current=True)
        current = self.store.current()
        self.assertIsNotNone(current)
        assert current is not None
        self.assertEqual(current.version_id, second.version_id)
        self.assertEqual(current.revision, 2)
        self.assertEqual(
            (first.version_dir / "localization_report.json").read_bytes(),
            first_report,
        )

    def test_invalid_diagnostic_version_never_becomes_current(self) -> None:
        diagnostic = self.commit_valid(state="invalid", update_current=False)
        self.assertEqual(diagnostic.state, "invalid")
        self.assertIsNone(self.store.current())
        self.assertTrue(diagnostic.version_dir.is_dir())

    def test_stale_staging_is_recovered_and_corrupt_pointer_fails_closed(self) -> None:
        stale = self.store.begin()
        (stale / "partial.json").write_text("{}", encoding="utf-8")
        self.store.prepare()
        self.assertFalse(stale.exists())
        snapshot = self.commit_valid()
        pointer = self.store.root / "current.json"
        payload = json.loads(pointer.read_text(encoding="utf-8"))
        payload["revision"] = snapshot.revision + 1
        pointer.write_text(json.dumps(payload), encoding="utf-8")
        with self.assertRaises(LocalizedStoreError):
            self.store.current()

    def test_state_transitions_create_new_versions_and_publication_audit(self) -> None:
        draft = self.commit_valid()
        review = self.store.transition_current(
            "review", actor="reviewer", reason="quality checks complete"
        )
        self.assertNotEqual(review.version_id, draft.version_id)
        self.assertEqual(review.state, "review")
        self.assertEqual(
            json.loads(
                (review.version_dir / "localization_report.json").read_text()
            )["publish_state"],
            "review",
        )
        published = self.store.transition_current(
            "published", actor="publisher", reason="explicit approval"
        )
        self.assertEqual(published.state, "published")
        self.assertEqual(self.store.published(), published)
        revoked = self.store.transition_current(
            "revoked", actor="publisher", reason="field issue"
        )
        self.assertEqual(revoked.state, "revoked")
        self.assertEqual(self.store.published(), revoked)
        self.assertIn(
            "localized_state_transition",
            (revoked.version_dir / "audit_log.jsonl").read_text(),
        )


if __name__ == "__main__":
    unittest.main()

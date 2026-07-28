from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[3]


class DocumentGovernanceTests(unittest.TestCase):
    def test_stale_review_and_prompt_files_are_not_repository_entrypoints(self) -> None:
        for name in ("code_review.md", "impl_prompts.md", "review_prompts.md"):
            self.assertFalse((ROOT / name).exists(), name)

    def test_review_and_prompt_history_declares_archive_status(self) -> None:
        history_roots = (
            ROOT / "docs/map-assisted-localization/reviews/history",
            ROOT / "docs/map-assisted-localization/agent-prompts/history",
        )
        for history_root in history_roots:
            for document in history_root.glob("*.md"):
                with self.subTest(document=document.name):
                    heading = document.read_text(encoding="utf-8")[:800]
                    self.assertIn("历史归档", heading)
                    self.assertIn("最后核对日期", heading)

    def test_current_review_binds_an_exact_baseline(self) -> None:
        current = (
            ROOT / "docs/map-assisted-localization/reviews/CURRENT_REVIEW.md"
        ).read_text(encoding="utf-8")
        self.assertIn("cf1b62c949f3574e1804808537e38c8ff643549c", current)
        self.assertIn(
            "MarketScanner_RepairV2_W2R_Production_Readiness_Code_Review_and_"
            "Final_Product_Agent_Spec_2026-07-28.md",
            current,
        )
        self.assertIn("repair-v2-p2-reproducible-release-build", current)
        self.assertIn("PRODUCTION_READINESS_REVIEW.md", current)
        self.assertIn("当前有效", current)

        production = (
            ROOT
            / "docs/map-assisted-localization/reviews/PRODUCTION_READINESS_REVIEW.md"
        ).read_text(encoding="utf-8")
        for blocker in ("RB-01", "RB-02", "RB-03", "RB-04", "RB-05"):
            self.assertIn(blocker, production)
        self.assertIn("NO-GO / NOT PRODUCTION READY", production)


if __name__ == "__main__":
    unittest.main()

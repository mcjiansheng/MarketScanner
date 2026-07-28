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
        self.assertIn("12715d4fd005dcd46cae015ab31882b732c8e570", current)
        self.assertIn("当前有效", current)


if __name__ == "__main__":
    unittest.main()

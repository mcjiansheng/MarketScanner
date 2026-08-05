# P7R6A Recovery persisted parser closeout review record

> Document status: **当前有效 / current and authoritative**. Last reconciled: 2026-08-04.
> Input prompt: `MarketScanner_P7R6A_Recovery_Persisted_Parser_Closeout_Prompt.md`.
> Base: `repair-v2-p7r6-recovery-evidence-integrity-closeout@4bce394bdfb7f6c7c2373f314814a3e3260356fe` (P7R6 implementation `a315ff6e5c0ca639f12c639aaf81be6738195e2f`).
> Implementation branch: `repair-v2-p7r6a-recovery-persisted-parser-closeout`; the exact P7R6A implementation SHA is bound in `.github/marketscanner-repair-v2-wave.json`.

## Findings closed this round

- **A. Coordinator parser split**: the coordinator decoded persisted lines with a plain `JSONDecoder`, disagreeing with the finalization validator on v1 records, blank/partial lines, unknown fields, and duplicate episodes. Closed by the shared strict parser `RecoveryLifecyclePersistedEvidenceParser` (`app/ios/RTABMapApp/RecoveryLifecycleEvidenceParser.swift`); the coordinator validates the whole stable snapshot through it before any append/ack, and finalization delegates the same parser (the duplicated recovery branch was removed from `SupermarketFinalizationCore`).
- **B. Missing final newline**: a complete JSON tail without `\n` could be acknowledged by the coordinator and later rejected by finalization. Closed: the parser rejects `missingFinalNewline`; the PC reader `_read_jsonl` enforces the same contract.
- **C. v1 readability**: auto `Decodable` could not read v1 records lacking the v2 non-optional fields. Closed: the parser is version-aware (`PersistedRecoveryLifecycleRecord` keeps v2-only facts nil for v1, never fabricates them); mixed v1/v2 files validate; same-episode v1/v2 is `persisted_episode_version_conflict`.
- **D. attemptedEpisodeIds semantics**: the result listed all pending IDs regardless of progress. Closed: only actually entered episodes are listed; pre-transaction failures report `[]` and never disguise a read/parse failure as an attempt on episode 1.
- **E. Exact-SHA automation**: rebinding executed on the final P7R6A HEAD (governance commit + wave descriptor); see CI status below.

## Stable failure vocabulary

Coordinator: `missing_prior_map_identity`, `existing_evidence_read_failed`, `existing_evidence_<parser stable code>` (e.g. `existing_evidence_missing_final_newline`, `existing_evidence_duplicate_episode`), `persisted_episode_version_conflict`, `persisted_episode_bytes_conflict`, `persisted_episode_order_conflict`, `pending_record_encoding_failed`, `durable_append_failed`. Parser stable codes: `file_too_large`, `missing_final_newline`, `blank_record`, `record_too_large`, `invalid_utf8`, `invalid_json`, `non_object`, `unknown_field`, `format_mismatch`, `version_mismatch`, `identity_mismatch`, `outcome_invalid`, `cancellation_reason_invalid`, `business_schema_invalid`, `trigger_records_invalid`, `duplicate_episode`, `episode_order_invalid`, `finish_order_invalid`, `expected_count_mismatch`, `last_episode_watermark_mismatch`, `last_finished_watermark_mismatch`. Finalization maps parser errors to the historical blocker strings (`legacyRecoveryReason`), keeping `evidence_bundle_recovery_watermark_mismatch` and every P7R6 blocker name intact.

## Executable evidence

- Swift host P-A1..P-A20: legal v1 + new v2 append and finalization, v1/v2 version conflict, missing final newline, blank line, partial tail, unknown field, duplicate episode, episode order, finish order, four identity fields, exact v2 idempotence without rewrite, three byte-conflict mutations, attempted-ID precision on first/second failures, snapshot parse failure, zero/positive watermark on empty snapshot, zero watermark with non-nil tail, stable-read same-size swap / truncate / symlink / hard-link fail-closed, mixed v1/v2 finalization under the exact watermark.
- Shared fixtures `tools/PriorMap/tests/fixtures/recovery_lifecycle/*.jsonl`: the Swift parser (host `--recovery-fixtures` mode) and the Python reader must produce the same category per fixture; the test asserts equality against the frozen category table.
- Regression: the full PriorMap suite (130 tests), Qualification, and SupermarketMapStudio suites pass on every commit.

## Status declarations

- IMPLEMENTED / UNIT TESTED / INTEGRATION TESTED: parser, coordinator, finalization delegation, v1 support, attempted semantics, fixtures.
- NOT RUN / PENDING at documentation time: exact-final-SHA seven-group CI on the P7R6A HEAD, clean Apple build, independent read-only review, human Sam re-test. Without those, `AUTOMATED CLOSEOUT PASS`, `APPLE BUILD VERIFIED`, `INDEPENDENT REVIEWED`, and `READY FOR HUMAN SAM RE-TEST` must not be declared.
- Forbidden at all times this round: `REAL DEVICE PASS`, `SAM FIELD PASS`, `PRODUCTION READY`. Release judgment stays **NO-GO / NOT PRODUCTION READY** until LiDAR real-device, same-route Sam, and on-site control-point tests complete.

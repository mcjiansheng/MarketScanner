# P7R6C independent review

> Review baseline: `repair-v2-p7r6b-strict-json-pending-queue-closeout@fd3fb4a84bd8da3770a81d455c2cc428f7479567` (P7R6B implementation SHA `fd3fb4a84bd8da3770a81d455c2cc428f7479567`).
> Review input: `MarketScanner_P7R6B_Code_Review_and_P7R6C_Fix_Prompt.md`.
> Review wave: `P7R6C-stable-input-total-json-closeout` on `repair-v2-p7r6c-stable-input-total-json-closeout`.
> Status: **reviewed in-place on the working tree; exact-final-SHA CI, clean Apple build, human Sam re-test and real-device runs remain NOT RUN.**

This review was conducted read-only on the P7R6C implementation (branch
`repair-v2-p7r6c-stable-input-total-json-closeout`) against the P7R6B
governance HEAD. The intent was to confirm that the six findings
(C1..C6) are closed without regressing any P7R2..P7R6B contract.

## C1 BLOCKER — Strict JSON validator must be a total function

The validator previously force-unwrapped the scanner stack
(`switch stack.last!`), so a document whose top-level value completed
before the trailing bytes (e.g. the U1 scalar-out-of-range sample, or a
random fuzz input) crashed the finalization process with a runtime trap
instead of failing closed. The implementation now:

- runs a strict RFC 3629 UTF-8 pass over the whole document before any
  structural decision (overlong, surrogate-encoded, above-U+10FFFF,
  bad-continuation and truncated sequences all reject with typed errors
  carrying byte offsets);
- scans the raw bytes through `withUnsafeBytes` with an explicit stack
  and a guard on the empty stack (top-level completion returns and lets
  `JSONSerialization` reject trailing garbage);
- decodes `\uXXXX` escapes with explicit high/low surrogate pairing
  (unpaired escapes are typed errors, legal pairs combine);
- never force-unwraps; every multibyte decode is guarded.

Executable evidence: C1-U1..U8 byte samples, U9 finalization blocker
with no crash and `finalized=false`, and U10/TJ9 10,000 deterministic
fuzz inputs of length 0..4096 that may only return or throw.

## C2 HIGH — fixed token cap must not reject legal large tag catalogs

The fixed 1,000,000-token cap is removed. `maximumIterations =
data.count * 4 + 1024` is a progress invariant that is provably above
any legal document (each iteration advances the index or performs at
most one transient push). The whole-array tag document is scanned and
parsed without copying the `Data`. `StrictJSONDocumentLimits` derives
limits from `maximumBytes`.

Executable evidence: C2-L1 (10k tags PASS), C2-L2 (30k PASS), C2-L3
(largest catalog that fits below the frozen 16 MiB limit PASS), C2-L4
(16 MiB + 1 byte fails the size limit), C2-L5 (duplicate key in the
last tag still detected), C2-L6 (numeric boolean in the last tag still
rejected). The duplicate-key scan plus `JSONSerialization` of the
largest fitting catalog measured ~44 MiB peak RSS and < 3 s on this
macOS host, within the L7/L8 gates.

## C3 BLOCKER — iOS prior-map package hash/parse TOCTOU

`PriorMapPackageSnapshotReader.read(directory:)` reads every
authoritative artifact exactly once through the descriptor-bound safe
path (`no-follow`, regular file, `st_nlink == 1`, size bounded,
pre/post read identity). The same bytes are hashed and (for JSON)
strictly parsed; integrity validation, format checks, model decoding
and previews (`UIImage(data:)`) all consume the snapshot. Frozen limits:
2 MiB package manifest, 64 MiB per JSON artifact, 64 MiB per preview,
512 MiB total, 128 artifacts.

Executable evidence: the `--integrity-suite` harness validates the
baseline PASS plus M1-M12 mutations in one process invocation:
same-size self-consistent replacement, symlink artifact, extra
hardlink, truncation, file-set change, preview swap, floor preview
swap, package-manifest duplicate key, nested elements duplicate key and
validation-report duplicate `valid`.

## C4 HIGH — PC finalized-session input identity must equal parsed bytes

`read_finalized_session_input_snapshot` reads metadata, the source
database, all JSONL sidecars and `localized_price_tags.json` exactly
once through descriptor-stable reads; the manifest identities are
derived from those same bytes, so `session_input_bundle_sha256`
describes exactly what localization parsed. `process_localized_session`
and `_render_localized_version` consume the snapshot; the source
database is never opened by SQLite directly — a descriptor-verified
immutable copy (Plan A) is created and verified against the snapshot
identity before the node-inventory audit. The metadata v1/v2 decision
and the metadata identity come from one stable read (S1); a
replacement between the manifest build and the snapshot read is caught
by the render before-check (S3); symlink/hardlink/truncate sidecars
(S4/S5/S6), tags swap (S7), recovery binding (S8) and source-DB
verified-copy mutation (S9) all fail closed; the bundle SHA recomputes
from the consumed artifact identities (S10).

## C5 HIGH — prior-map strict JSON schema completeness

The shared `strict_json` helpers back `prior_map_schema.load_json` and
every offline JSON/JSONL reader (strict UTF-8, NaN rejection,
duplicate-key rejection before last-key-wins, iterative nesting depth);
the iOS integrity validator reads integers/numbers/booleans/geometry/
bounds through `StrictJSONScalar`. N1-N9 reject fractional versions,
boolean counts/bytes/visibility, boolean coordinates/bounds and
duplicate or escaped-equivalent keys; N10 keeps Swift/PC parity through
the shared fixtures.

## C6 RELEASE GATE — exact-SHA CI

The CI `swiftc -parse` list, the Swift host compile list and the Xcode
project register the two new Swift files
(`StrictJSONDocumentParser.swift`, `PriorMapPackageSnapshotCore.swift`).
The platform-independent contract job runs the Swift host and the C4
snapshot suites. The exact-final-SHA seven-group CI on the P7R6C HEAD,
the clean Apple build, the independent read-only review, and the human
Sam re-test remain NOT RUN and must not be reported as PASS; the release
judgment stays **NO-GO / NOT PRODUCTION READY**, and `REAL DEVICE
PASS` / `SAM FIELD PASS` / `PRODUCTION READY` remain forbidden until
LiDAR real-device, same-route Sam, and on-site control-point tests
complete.

## Regression check

P7R2 global alignment, P7R3 episode budget/freshness, P7R4
confidence/provisional/deadline, P7R5 cooldown/cancellation/elapsed,
P7R6 watermark/input-manifest-v2/schema, P7R6A persisted-parser and
P7R6B strict-json/pending-queue contracts remain unchanged; the Swift
host P-A/P-B suites and the shared Swift/PC fixture alignment still
pass, and the PC reader, MapStudio and Qualification suites are green.

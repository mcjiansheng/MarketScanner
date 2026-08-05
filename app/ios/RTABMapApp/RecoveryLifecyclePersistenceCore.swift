// P7R6: Foundation-only transaction coordinator that persists terminal
// Recovery lifecycle evidence with a peek/ack protocol. Completions stay
// queued in the localizer until the durable append is confirmed, so a failed
// write keeps the retryable state visible and auditable instead of draining
// it before acknowledgement.
//
// Callers must serialize coordinator invocations on a single queue (the
// prior-map queue in production); the coordinator itself holds no locks so a
// wrong-queue call can be rejected by the caller's dispatch policy instead
// of deadlocking here.

import Foundation

/// Peek/ack source of terminal Recovery completions. Unlike a drain, peeking
/// leaves every completion queued until `acknowledgeTerminalRecoveryCompletion`
/// confirms the durable write for its episode.
protocol RecoveryCompletionDraining {
    func cancelRecovery(
        reason: PriorMapRecoveryCancellationReason,
        now: TimeInterval
    ) -> PriorMapRecoveryCompletion?

    func pendingTerminalRecoveryCompletions()
        -> [PriorMapRecoveryCompletion]

    func acknowledgeTerminalRecoveryCompletion(episodeId: Int)

    func discardTerminalRecoveryCompletionsForInvalidatedSession()
}

/// Durable sidecar writer. Implementations must only return true after the
/// record bytes reached the file system and the session identity matched.
protocol RecoveryLifecycleWriting {
    func appendRecoveryLifecycleEvent(
        _ completion: PriorMapRecoveryCompletion,
        expectedTrackingSessionId: String
    ) -> Bool
}

/// Structured transaction outcome. A bare Bool is forbidden: audit paths must
/// be able to distinguish "nothing pending", "partially persisted", and the
/// exact episode where the transaction stopped.
///
/// `attemptedEpisodeIds` lists only episodes the transaction actually
/// entered. Pre-transaction failures (missing identity, unreadable or
/// unparsable existing snapshot) happen before any pending episode is
/// attempted, so they report an empty list; a read or parse failure must
/// never be disguised as an attempt on the first pending episode.
struct RecoveryLifecyclePersistenceResult {
    let attemptedEpisodeIds: [Int]
    let persistedEpisodeIds: [Int]
    let failedEpisodeId: Int?
    let failureReason: String?
    let allPersisted: Bool
}

/// Runs one teardown-to-disk transaction:
///
/// ```text
/// optional cancel -> peek pending
///   -> stable read the entire existing snapshot
///   -> strict parse the entire snapshot through the shared parser
///   -> only then: append in episode ID order
///       -> durable success -> ack -> next
///       -> identical persisted v2 record -> ack without rewrite
///       -> failure/conflict -> stop, keep the completion and everything
///          after it
/// ```
///
/// Idempotence strategy A (P7R6A): the coordinator validates the complete
/// persisted snapshot with the same strict parser finalization uses before
/// acknowledging anything, so a file the coordinator would accept can never
/// be rejected later by finalization. A repeated episode whose persisted
/// canonical v2 bytes equal the pending canonical bytes counts as already
/// persisted; a v1 record can never be merged with a pending v2 episode and
/// different bytes for the same episode ID fail closed.
final class RecoveryLifecyclePersistenceCoordinator {
    private let source: RecoveryCompletionDraining
    private let writer: RecoveryLifecycleWriting
    private let trackingSessionId: String
    private let priorMapId: String?
    private let priorMapSha256: String?
    private let floorId: String?
    private let persistedEvidenceSnapshot: () throws -> Data

    init(
        source: RecoveryCompletionDraining,
        writer: RecoveryLifecycleWriting,
        trackingSessionId: String,
        priorMapId: String?,
        priorMapSha256: String?,
        floorId: String?,
        persistedEvidenceSnapshot: @escaping () throws -> Data
    ) {
        self.source = source
        self.writer = writer
        self.trackingSessionId = trackingSessionId
        self.priorMapId = priorMapId
        self.priorMapSha256 = priorMapSha256
        self.floorId = floorId
        self.persistedEvidenceSnapshot = persistedEvidenceSnapshot
    }

    @discardableResult
    func persistTerminalEvidence(
        cancellationReason: PriorMapRecoveryCancellationReason?,
        now: TimeInterval
    ) -> RecoveryLifecyclePersistenceResult {
        if let cancellationReason {
            _ = source.cancelRecovery(reason: cancellationReason, now: now)
        }
        let pending = source.pendingTerminalRecoveryCompletions()
            .sorted { $0.episode.id < $1.episode.id }
        guard !pending.isEmpty else {
            return RecoveryLifecyclePersistenceResult(
                attemptedEpisodeIds: [],
                persistedEpisodeIds: [],
                failedEpisodeId: nil,
                failureReason: nil,
                allPersisted: true)
        }
        let firstPendingEpisodeId = pending[0].episode.id
        guard let priorMapId, let priorMapSha256, let floorId else {
            return RecoveryLifecyclePersistenceResult(
                attemptedEpisodeIds: [],
                persistedEpisodeIds: [],
                failedEpisodeId: firstPendingEpisodeId,
                failureReason: "missing_prior_map_identity",
                allPersisted: false)
        }
        // Stable pre-append snapshot for idempotence strategy A. A read
        // failure must not be masked by blind rewrites.
        let snapshot: Data
        do {
            snapshot = try persistedEvidenceSnapshot()
        }
        catch {
            return RecoveryLifecyclePersistenceResult(
                attemptedEpisodeIds: [],
                persistedEpisodeIds: [],
                failedEpisodeId: firstPendingEpisodeId,
                failureReason: "existing_evidence_read_failed",
                allPersisted: false)
        }
        // The whole snapshot must pass the same strict parser finalization
        // uses before any pending completion may be appended or
        // acknowledged.
        let parsed: ParsedRecoveryLifecycleEvidence
        do {
            parsed = try RecoveryLifecyclePersistedEvidenceParser.parse(
                snapshot: snapshot,
                expectation: RecoveryLifecycleEvidenceExpectation(
                    trackingSessionId: trackingSessionId,
                    priorMapId: priorMapId,
                    priorMapSha256: priorMapSha256,
                    floorId: floorId))
        }
        catch let error as RecoveryLifecycleEvidenceParseError {
            return RecoveryLifecyclePersistenceResult(
                attemptedEpisodeIds: [],
                persistedEpisodeIds: [],
                failedEpisodeId: firstPendingEpisodeId,
                failureReason:
                    "existing_evidence_\(error.stableCode)",
                allPersisted: false)
        }
        catch {
            return RecoveryLifecyclePersistenceResult(
                attemptedEpisodeIds: [],
                persistedEpisodeIds: [],
                failedEpisodeId: firstPendingEpisodeId,
                failureReason: "existing_evidence_read_failed",
                allPersisted: false)
        }
        var attemptedIds: [Int] = []
        var persistedIds: [Int] = []
        for completion in pending {
            let episodeId = completion.episode.id
            attemptedIds.append(episodeId)
            let record = PriorMapRecoveryLifecycleRecord(
                trackingSessionId: trackingSessionId,
                priorMapId: priorMapId,
                priorMapSha256: priorMapSha256,
                floorId: floorId,
                completion: completion)
            let pendingCanonicalBytes: Data
            do {
                pendingCanonicalBytes =
                    try RecoveryLifecyclePersistedEvidenceParser
                        .canonicalPendingRecordBytes(record)
            }
            catch {
                return RecoveryLifecyclePersistenceResult(
                    attemptedEpisodeIds: attemptedIds,
                    persistedEpisodeIds: persistedIds,
                    failedEpisodeId: episodeId,
                    failureReason: "pending_record_encoding_failed",
                    allPersisted: false)
            }
            if let existing = parsed.recordsByEpisodeId[episodeId] {
                // A historical v1 record and a pending v2 record for the
                // same episode are never the same fact: no fabricated v2
                // upgrade, no idempotent merge.
                guard existing.version == 2 else {
                    return RecoveryLifecyclePersistenceResult(
                        attemptedEpisodeIds: attemptedIds,
                        persistedEpisodeIds: persistedIds,
                        failedEpisodeId: episodeId,
                        failureReason: "persisted_episode_version_conflict",
                        allPersisted: false)
                }
                if existing.canonicalRecordBytes == pendingCanonicalBytes {
                    // Crash between durable append and ack: the evidence is
                    // already on disk with identical content. Acknowledge
                    // without rewriting so the watermark stays exact.
                    persistedIds.append(episodeId)
                    source.acknowledgeTerminalRecoveryCompletion(
                        episodeId: episodeId)
                    continue
                }
                return RecoveryLifecyclePersistenceResult(
                    attemptedEpisodeIds: attemptedIds,
                    persistedEpisodeIds: persistedIds,
                    failedEpisodeId: episodeId,
                    failureReason: "persisted_episode_bytes_conflict",
                    allPersisted: false)
            }
            guard writer.appendRecoveryLifecycleEvent(
                completion,
                expectedTrackingSessionId: trackingSessionId) else {
                // Keep this completion and every later one queued so the
                // failure stays retryable and auditable.
                return RecoveryLifecyclePersistenceResult(
                    attemptedEpisodeIds: attemptedIds,
                    persistedEpisodeIds: persistedIds,
                    failedEpisodeId: episodeId,
                    failureReason: "durable_append_failed",
                    allPersisted: false)
            }
            persistedIds.append(episodeId)
            source.acknowledgeTerminalRecoveryCompletion(
                episodeId: episodeId)
        }
        return RecoveryLifecyclePersistenceResult(
            attemptedEpisodeIds: attemptedIds,
            persistedEpisodeIds: persistedIds,
            failedEpisodeId: nil,
            failureReason: nil,
            allPersisted: true)
    }
}

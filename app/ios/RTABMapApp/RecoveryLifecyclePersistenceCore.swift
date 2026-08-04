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
/// optional cancel -> peek pending -> append in episode ID order
///   -> durable success -> ack -> next
///   -> failure -> stop, keep the completion and everything after it
/// ```
///
/// Idempotence strategy A: before appending, the coordinator takes a stable
/// snapshot of the persisted evidence. A repeated episode whose persisted
/// record equals the record about to be written counts as already persisted;
/// different bytes for the same episode ID fail closed.
final class RecoveryLifecyclePersistenceCoordinator {
    private let source: RecoveryCompletionDraining
    private let writer: RecoveryLifecycleWriting
    private let trackingSessionId: String
    private let priorMapId: String?
    private let priorMapSha256: String?
    private let floorId: String?
    private let persistedEvidenceLines: () throws -> [Data]

    init(
        source: RecoveryCompletionDraining,
        writer: RecoveryLifecycleWriting,
        trackingSessionId: String,
        priorMapId: String?,
        priorMapSha256: String?,
        floorId: String?,
        persistedEvidenceLines: @escaping () throws -> [Data]
    ) {
        self.source = source
        self.writer = writer
        self.trackingSessionId = trackingSessionId
        self.priorMapId = priorMapId
        self.priorMapSha256 = priorMapSha256
        self.floorId = floorId
        self.persistedEvidenceLines = persistedEvidenceLines
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
        let attemptedIds = pending.map { $0.episode.id }
        guard let priorMapId, let priorMapSha256, let floorId else {
            return RecoveryLifecyclePersistenceResult(
                attemptedEpisodeIds: attemptedIds,
                persistedEpisodeIds: [],
                failedEpisodeId: attemptedIds.first,
                failureReason: "missing_prior_map_identity",
                allPersisted: false)
        }
        // Stable pre-append snapshot for idempotence strategy A. A read
        // failure must not be masked by blind rewrites.
        let persistedByEpisode: [Int: PriorMapRecoveryLifecycleRecord]
        do {
            var observed: [Int: PriorMapRecoveryLifecycleRecord] = [:]
            for line in try persistedEvidenceLines() where !line.isEmpty {
                let record = try JSONDecoder().decode(
                    PriorMapRecoveryLifecycleRecord.self,
                    from: line)
                guard observed[record.episodeId] == nil else {
                    return RecoveryLifecyclePersistenceResult(
                        attemptedEpisodeIds: attemptedIds,
                        persistedEpisodeIds: [],
                        failedEpisodeId: attemptedIds.first,
                        failureReason:
                            "existing_evidence_duplicate_episode",
                        allPersisted: false)
                }
                observed[record.episodeId] = record
            }
            persistedByEpisode = observed
        }
        catch {
            return RecoveryLifecyclePersistenceResult(
                attemptedEpisodeIds: attemptedIds,
                persistedEpisodeIds: [],
                failedEpisodeId: attemptedIds.first,
                failureReason: "existing_evidence_read_failed",
                allPersisted: false)
        }
        var persistedIds: [Int] = []
        for completion in pending {
            let episodeId = completion.episode.id
            let record = PriorMapRecoveryLifecycleRecord(
                trackingSessionId: trackingSessionId,
                priorMapId: priorMapId,
                priorMapSha256: priorMapSha256,
                floorId: floorId,
                completion: completion)
            if let existing = persistedByEpisode[episodeId] {
                if existing == record {
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

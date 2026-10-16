import Foundation

/// Files a finished call into retrieval.
///
/// Two notes per call — the recap and the transcript — so a question about
/// what was decided finds the recap and a question about who said what finds
/// the transcript, without one crowding the other out of a three-passage
/// budget. Both are `call_history`: searched, never packed or listed.
public enum CallHistoryIndex {
    public static func summaryID(_ callID: String) -> String { "call-history-\(callID)-summary" }
    public static func transcriptID(_ callID: String) -> String { "call-history-\(callID)-transcript" }
}

public extension CallaStore {
    /// Creates or replaces both notes for one call. Idempotent: re-indexing
    /// after the accurate transcript lands replaces the live one.
    func indexCallHistory(callID: String, scope: KnowledgeScope, title: String,
                          summary: String, transcript: String, at date: Date) async throws {
        for (id, label, body) in [(CallHistoryIndex.summaryID(callID), title, summary),
                                  (CallHistoryIndex.transcriptID(callID), "\(title) — transcript", transcript)] {
            let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            try await upsert(KnowledgeNote(
                id: id, title: label, body: text, source: .callHistory, scope: scope,
                createdAt: date, updatedAt: date, byteSize: text.utf8.count))
        }
    }

    /// Whether a call has been indexed, so a backfill can skip it.
    func isCallHistoryIndexed(callID: String) throws -> Bool {
        try scalarInt("SELECT COUNT(*) FROM knowledge_note WHERE id = ?",
                      [.text(CallHistoryIndex.summaryID(callID))]) ?? 0 > 0
    }
}

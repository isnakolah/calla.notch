import Foundation
import CallaContracts

public enum CallKnowledgeSnapshotError: Error, Equatable, Sendable {
    case callMissing
    case alreadyFrozen
    case sourceMissing(String)
}

public extension CallaStore {
    /// Copies exact selected revisions and chunks. Existing snapshot is never
    /// updated; running-call knowledge therefore cannot drift under later edits.
    func freezeKnowledge(
        callID: String,
        generation: Int,
        noteIDs: [String],
        glossary: [String] = []
    ) throws -> CallKnowledgeSnapshot {
        guard try call(id: callID) != nil else { throw CallKnowledgeSnapshotError.callMissing }
        guard try scalarInt("SELECT COUNT(*) FROM call_knowledge_snapshot WHERE call_id = ?", [.text(callID)]) == 0
        else { throw CallKnowledgeSnapshotError.alreadyFrozen }

        let uniqueIDs = Array(Set(noteIDs)).sorted()
        struct Row {
            var noteID: String; var title: String; var source: KnowledgeSource
            var updatedAt: Date; var ordinal: Int; var text: String
            var page: Int?; var section: String?; var embedding: Data?
        }
        var rows: [Row] = []
        for noteID in uniqueIDs {
            let selected = try query(
                """
                SELECT n.id, COALESCE(n.origin_name, n.title), n.source, n.updated_at,
                       c.ord, c.text, c.page, c.section, c.embedding
                FROM knowledge_note n JOIN knowledge_chunk c ON c.note_id = n.id
                WHERE n.id = ? ORDER BY c.ord
                """, [.text(noteID)]) { row in
                    Row(noteID: row.string(0), title: row.string(1),
                        source: KnowledgeSource(rawValue: row.string(2)) ?? .manual,
                        updatedAt: row.date(3) ?? Date(timeIntervalSince1970: 0),
                        ordinal: row.int(4), text: row.string(5),
                        page: row.intIfPresent(6), section: row.text(7), embedding: row.blob(8))
                }
            guard !selected.isEmpty else { throw CallKnowledgeSnapshotError.sourceMissing(noteID) }
            rows += selected
        }

        let formatter = ISO8601DateFormatter()
        let revisions = rows.reduce(into: [String: String]()) { result, row in
            result[row.noteID] = formatter.string(from: row.updatedAt)
        }
        let chunks = rows.map { row -> CallKnowledgeChunk in
            let revision = revisions[row.noteID] ?? "unknown"
            let citationID = "pack-\(row.noteID)-\(row.ordinal)"
            let kind: KnowledgeCitationKind = row.source == .document ? .document : .note
            return CallKnowledgeChunk(
                citation: KnowledgeCitation(
                    id: citationID, kind: kind, label: row.title,
                    sourceID: row.noteID, revision: revision,
                    page: row.page, section: row.section),
                text: row.text)
        }
        let frozenAt = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 * 1_000).rounded(.down) / 1_000)
        let snapshot = CallKnowledgeSnapshot(
            callID: callID, generation: generation, createdAt: frozenAt, sourceRevisions: revisions,
            chunks: chunks, glossary: glossary)
        let revisionsData = try JSONEncoder().encode(revisions)
        let glossaryData = try JSONEncoder().encode(snapshot.glossary)

        try database.transaction {
            try database.run(
                "INSERT INTO call_knowledge_snapshot(call_id, generation, created_at, revisions_json, glossary_json) VALUES(?, ?, ?, ?, ?)",
                [.text(callID), .int(generation), .date(snapshot.createdAt),
                 .text(String(decoding: revisionsData, as: UTF8.self)),
                 .text(String(decoding: glossaryData, as: UTF8.self))])
            for (index, chunk) in chunks.enumerated() {
                try database.run(
                    """
                    INSERT INTO call_knowledge_chunk(call_id, citation_id, source_id, revision,
                      kind, label, page, section, text, embedding) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [.text(callID), .text(chunk.citation.id), .text(chunk.citation.sourceID),
                     .text(chunk.citation.revision), .text(chunk.citation.kind.rawValue),
                     .text(chunk.citation.label), .int(chunk.citation.page),
                     .text(chunk.citation.section), .text(chunk.text), .blob(rows[index].embedding)])
            }
        }
        return snapshot
    }

    func knowledgeSnapshot(forCall callID: String) throws -> CallKnowledgeSnapshot? {
        struct Header { var generation: Int; var at: Date; var revisions: String; var glossary: String }
        guard let header = try query(
            "SELECT generation, created_at, revisions_json, glossary_json FROM call_knowledge_snapshot WHERE call_id = ?",
            [.text(callID)], row: { Header(generation: $0.int(0), at: $0.date(1) ?? Date(),
                                     revisions: $0.string(2), glossary: $0.string(3)) }).first
        else { return nil }
        let chunks = try snapshotChunks(callID: callID)
        let decoder = JSONDecoder()
        return CallKnowledgeSnapshot(
            callID: callID, generation: header.generation, createdAt: header.at,
            sourceRevisions: (try? decoder.decode([String: String].self, from: Data(header.revisions.utf8))) ?? [:],
            chunks: chunks,
            glossary: (try? decoder.decode([String].self, from: Data(header.glossary.utf8))) ?? [])
    }

    /// Scoped hybrid ranking over frozen rows. BM25 and copied embeddings are
    /// fused by rank, then exact filename/title/entity matches boost results.
    /// Mutable knowledge tables are never consulted after freeze.
    func searchSnapshot(query: String, callID: String, limit: Int = 4,
                        promptCharacterLimit: Int = 1_800) async throws -> [CallKnowledgeChunk] {
        let queryTokens = Self.ragTokens(query)
        let queryTerms = Set(queryTokens)
        guard !queryTerms.isEmpty else { return [] }
        let candidates = try snapshotCandidates(callID: callID)
        guard !candidates.isEmpty else { return [] }

        let tokenized = candidates.map { Self.ragTokens($0.chunk.text + " " + $0.chunk.citation.label) }
        let averageLength = max(1, Double(tokenized.map(\.count).reduce(0, +)) / Double(tokenized.count))
        var documentFrequency: [String: Int] = [:]
        for terms in tokenized.map(Set.init) {
            for term in terms where queryTerms.contains(term) { documentFrequency[term, default: 0] += 1 }
        }

        let count = Double(candidates.count)
        var lexical: [(Int, Double)] = []
        var boosts: [Int: Double] = [:]
        let lowerQuery = query.lowercased()
        let entities = query.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { $0.first?.isUppercase == true && !Self.ragStopWords.contains($0.lowercased()) }
            .map { $0.lowercased() }
        for index in candidates.indices {
            let terms = tokenized[index]
            let frequencies = Dictionary(grouping: terms, by: { $0 }).mapValues(\.count)
            var score = 0.0
            for term in queryTerms {
                guard let frequency = frequencies[term], frequency > 0 else { continue }
                let df = Double(documentFrequency[term, default: 0])
                let idf = log(1 + (count - df + 0.5) / (df + 0.5))
                let tf = Double(frequency)
                let length = Double(terms.count)
                let denominator = tf + 1.2 * (1 - 0.75 + 0.75 * length / averageLength)
                score += idf * (tf * 2.2 / denominator)
            }
            if score > 0 { lexical.append((index, score)) }

            let label = candidates[index].chunk.citation.label.lowercased()
            let labelTerms = Set(Self.ragTokens(label))
            var boost = Double(queryTerms.intersection(labelTerms).count) * 0.025
            if !label.isEmpty, lowerQuery.contains(label) || label.contains(lowerQuery) { boost += 0.08 }
            boost += Double(entities.filter(label.contains).count) * 0.04
            boosts[index] = boost
        }
        lexical.sort { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }

        var vector: [(Int, Double)] = []
        if embeddingsReady, let target = await embedder.embed(query) {
            vector = candidates.indices.compactMap { index in
                guard let blob = candidates[index].embedding else { return nil }
                let similarity = VectorBlob.similarity(target, VectorBlob.decode(blob))
                guard similarity > 0.2 else { return nil }
                return (index, similarity)
            }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
        }

        var fused: [Int: Double] = boosts
        for (rank, entry) in lexical.enumerated() { fused[entry.0, default: 0] += 1 / (60 + Double(rank + 1)) }
        for (rank, entry) in vector.enumerated() { fused[entry.0, default: 0] += 1 / (60 + Double(rank + 1)) }
        let lexicalIDs = Set(lexical.map(\.0))
        let vectorScores = Dictionary(uniqueKeysWithValues: vector)
        let scored = fused.compactMap { index, score -> (CallKnowledgeChunk, Double)? in
            // No padding: require lexical evidence or a meaningful semantic hit.
            guard lexicalIDs.contains(index) || vectorScores[index, default: 0] >= 0.28 else { return nil }
            return (candidates[index].chunk, score)
        }.sorted { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0.citation.id < rhs.0.citation.id : lhs.1 > rhs.1
        }

        var result: [CallKnowledgeChunk] = []
        var perSource: [String: Int] = [:]
        var seenPassages = Set<String>()
        var used = 0
        for (chunk, _) in scored {
            guard result.count < min(4, max(0, limit)) else { break }
            let source = chunk.citation.sourceID ?? chunk.citation.id
            guard perSource[source, default: 0] < 2 else { continue }
            guard seenPassages.insert(Self.passageFingerprint(chunk.text)).inserted else { continue }
            let remaining = promptCharacterLimit - used
            guard remaining > 0 else { break }
            var bounded = chunk
            bounded.text = String(chunk.text.prefix(remaining))
            guard !bounded.text.isEmpty else { break }
            result.append(bounded)
            used += bounded.text.count
            perSource[source, default: 0] += 1
        }
        return result
    }

    func record(question: CallQuestion) throws {
        guard let callID = question.callID, let generation = question.generation else { return }
        let payload = try JSONEncoder().encode(question)
        try run(
            "INSERT INTO call_question_v3(id, call_id, generation, payload_json, detected_at) VALUES(?, ?, ?, ?, ?) " +
            "ON CONFLICT(id) DO UPDATE SET payload_json = excluded.payload_json",
            [.text(question.id.uuidString), .text(callID), .int(generation),
             .text(String(decoding: payload, as: UTF8.self)), .date(question.detectedAt)])
    }

    func record(answer: CallAnswer) throws {
        let payload = try JSONEncoder().encode(answer)
        let published = answer.timing.enginePublishedAt ?? answer.timing.providerCompletedAt
        try run(
            "INSERT INTO call_answer_v3(id, call_id, generation, question_id, payload_json, published_at) VALUES(?, ?, ?, ?, ?, ?) " +
            "ON CONFLICT(id) DO UPDATE SET payload_json = excluded.payload_json",
            [.text(answer.id), .text(answer.callID), .int(answer.generation),
             .text(answer.questionID.uuidString), .text(String(decoding: payload, as: UTF8.self)),
             .date(published)])
    }

    func questions(forCall callID: String) throws -> [CallQuestion] {
        let rows = try query("SELECT payload_json FROM call_question_v3 WHERE call_id = ? ORDER BY detected_at",
                             [.text(callID)]) { $0.string(0) }
        return rows.compactMap { try? JSONDecoder().decode(CallQuestion.self, from: Data($0.utf8)) }
    }

    func answers(forCall callID: String) throws -> [CallAnswer] {
        let rows = try query("SELECT payload_json FROM call_answer_v3 WHERE call_id = ? ORDER BY published_at",
                             [.text(callID)]) { $0.string(0) }
        return rows.compactMap { try? JSONDecoder().decode(CallAnswer.self, from: Data($0.utf8)) }
    }

    func deleteCall(id: String) throws {
        try run("DELETE FROM call WHERE id = ?", [.text(id)])
        try run("DELETE FROM knowledge_note WHERE source = 'call_history' AND id IN (?, ?)",
                [.text(CallHistoryIndex.summaryID(id)), .text(CallHistoryIndex.transcriptID(id))])
    }

    private func snapshotChunks(callID: String) throws -> [CallKnowledgeChunk] {
        try snapshotCandidates(callID: callID).map(\.chunk)
    }

    private struct SnapshotCandidate {
        var chunk: CallKnowledgeChunk
        var embedding: Data?
    }

    private func snapshotCandidates(callID: String) throws -> [SnapshotCandidate] {
        try query(
            """
            SELECT citation_id, kind, label, source_id, revision, page, section, text, embedding
            FROM call_knowledge_chunk WHERE call_id = ? ORDER BY id
            """, [.text(callID)]) { row in
                SnapshotCandidate(
                    chunk: CallKnowledgeChunk(
                        citation: KnowledgeCitation(
                            id: row.string(0), kind: KnowledgeCitationKind(rawValue: row.string(1)) ?? .note,
                            label: row.string(2), sourceID: row.text(3), revision: row.text(4),
                            page: row.intIfPresent(5), section: row.text(6)),
                        text: row.string(7)),
                    embedding: row.blob(8))
            }
    }

    private static func ragTokens(_ value: String) -> [String] {
        value.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init).filter { $0.count > 1 && !ragStopWords.contains($0) }
    }

    private static let ragStopWords: Set<String> = [
        "what", "when", "where", "which", "who", "why", "how", "does", "did",
        "the", "and", "for", "with", "from", "this", "that", "about", "are", "was"
    ]
}

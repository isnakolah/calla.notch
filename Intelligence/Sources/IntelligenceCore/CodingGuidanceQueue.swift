import CallaContracts
import Foundation

/// Accepted requests stay FIFO within a priority. A busy model must not erase
/// the next question.  Capacity failures are explicit so the UI can ask the
/// candidate to repeat.
///
/// Priority exists because the lane is serial and the model costs seconds. An
/// interviewer's question arriving behind two pieces of candidate narration used
/// to wait for both of them, which is longer than the model itself takes — and
/// by the time the narration was answered, the answer was about a moment that
/// had passed. So a question goes to the front, and the narration it overtook is
/// dropped rather than answered late: a pointer about a sentence the interview
/// has already moved past is worth less than nothing on a panel someone is
/// reading mid-sentence.
///
/// Urgent requests keep their order among themselves. Two questions in a row are
/// both real, and the second is not more urgent than the first.
public struct CodingGuidanceQueue: Sendable {
    public enum Admission: Equatable, Sendable { case accepted, duplicate, full }
    public struct Request: Sendable, Equatable {
        public var statement: Statement
        /// Capture the referent of "that" when heard, not when the worker frees.
        public var context: [Statement]
        public var priority: CodingMovePriority
    }
    public private(set) var pending: [Request] = []
    private let capacity: Int

    public init(capacity: Int = 8) { self.capacity = max(1, capacity) }

    public mutating func enqueue(_ statement: Statement, context: [Statement] = [],
                                 priority: CodingMovePriority = .advisory) -> Admission {
        if pending.contains(where: { $0.statement == statement }) { return .duplicate }
        let request = Request(statement: statement,
                              context: Self.referent(of: statement, in: context),
                              priority: priority)
        guard priority == .urgent else {
            guard pending.count < capacity else { return .full }
            pending.append(request)
            return .accepted
        }
        // Narration the interview has already moved past. Dropping it is what
        // makes room, so an urgent request is never refused for capacity.
        pending.removeAll { $0.priority != .urgent }
        let insert = pending.lastIndex { $0.priority == .urgent }.map { $0 + 1 } ?? 0
        pending.insert(request, at: insert)
        return .accepted
    }

    public mutating func next() -> Request? {
        pending.isEmpty ? nil : pending.removeFirst()
    }

    public mutating func reset() { pending.removeAll(keepingCapacity: true) }

    /// The few statements before this one, which is what "that" points at.
    private static func referent(of statement: Statement,
                                 in context: [Statement]) -> [Statement] {
        Array(context.filter { $0.toSeq < statement.fromSeq }.suffix(4))
    }
}

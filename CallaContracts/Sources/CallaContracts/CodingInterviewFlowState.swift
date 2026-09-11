import Foundation

public enum CodingInterviewStage: String, Codable, CaseIterable, Sendable {
    case understanding, reasoning, simple, hardening, optimization, verification, concluded
    public var isImplementation: Bool { [.simple, .hardening, .optimization].contains(self) }
    public var cue: String {
        switch self {
        case .hardening: "Let's handle the edge cases."
        case .optimization: "Let's improve the complexity."
        case .verification, .concluded: "Let's review what the checks demonstrate."
        default: "Let's implement the simple version."
        }
    }
}
public enum CodingReasoningStep: String, Codable, CaseIterable, Sendable {
    case example, approach, correctness, complexity
}
public enum CodingFactKind: String, Codable, Sendable {
    case interviewerRequirement, candidateChoice, assumption
}
public struct CodingDialogueEvidence: Codable, Equatable, Sendable {
    public var anchor: CodingTextAnchor
    public var speaker: CodingSpeaker
    public var quote: String
    public init(anchor: CodingTextAnchor, speaker: CodingSpeaker, quote: String) {
        self.anchor = anchor; self.speaker = speaker; self.quote = quote
    }
}
public struct CodingDialogueFact: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var text: String
    public var kind: CodingFactKind
    public var evidence: [CodingDialogueEvidence]
    public init(id: String, text: String, kind: CodingFactKind, evidence: [CodingDialogueEvidence]) {
        self.id = id; self.text = text; self.kind = kind; self.evidence = evidence
    }
}
public struct CodingClarification: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var question: String
    public var allowsYesNo: Bool
    /// Nil until the question was actually spoken. A displayed question is only a suggestion.
    public var asked: CodingDialogueEvidence?
    public var answer: String?
    public var evidence: [CodingDialogueEvidence]
    public var resolved: Bool
    public init(id: String, question: String, allowsYesNo: Bool = false,
                asked: CodingDialogueEvidence? = nil, answer: String? = nil,
                evidence: [CodingDialogueEvidence] = [], resolved: Bool = false) {
        self.id = id; self.question = question; self.allowsYesNo = allowsYesNo
        self.asked = asked; self.answer = answer; self.evidence = evidence; self.resolved = resolved
    }
}
public struct CodingSavedEvidence: Codable, Equatable, Sendable {
    public var sourceRevision: String
    public var path: String
    public var excerpt: String
    public init(sourceRevision: String, path: String, excerpt: String) {
        self.sourceRevision = sourceRevision; self.path = path; self.excerpt = excerpt
    }
}
public struct CodingPendingWork: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var text: String
    public var stage: CodingInterviewStage
    public var required: Bool
    public var requirementIDs: [String]
    public var completedEvidence: CodingSavedEvidence?
    public init(id: String, text: String, stage: CodingInterviewStage, required: Bool = true,
                requirementIDs: [String] = [], completedEvidence: CodingSavedEvidence? = nil) {
        self.id = id; self.text = text; self.stage = stage; self.required = required
        self.requirementIDs = requirementIDs; self.completedEvidence = completedEvidence
    }
}
/// Persisted conversation context shared by generic Code and Wave. No model field grants authority.
public struct CodingInterviewFlowState: Codable, Equatable, Sendable {
    public var sessionID: String
    public var generation: Int
    public var sourceRevision: String
    public var brief: InterviewBrief?
    public var requirementRevision = 0
    public var taskRevision = 0
    public var stage: CodingInterviewStage = .understanding
    public var nextStage: CodingInterviewStage = .simple
    public var authorizedStage: CodingInterviewStage?
    public var authorizedPendingIDs: [String]?
    public var authorization: CodingDialogueEvidence?
    public var clarification: CodingClarification?
    public var clarificationHistory: [CodingClarification] = []
    public var reasoningStep: CodingReasoningStep = .example
    public var discussed: [CodingReasoningStep: [CodingDialogueEvidence]] = [:]
    public var facts: [CodingDialogueFact] = []
    public var pending: [CodingPendingWork] = []
    public var pointers: [String] = []
    public var limitation: String?
    public var retry: String?
    public var held = false
    public var spokenQuestionArmed = false
    public var foregroundQuestionID: String?
    public var questionOwners: [String: String] = [:]
    public var transcript: [CodingDialogueEvidence] = []
    public var checkedSourceRevision: String?
    public init(sessionID: String, generation: Int, sourceRevision: String) {
        self.sessionID = sessionID; self.generation = generation; self.sourceRevision = sourceRevision
    }
    public var pendingRequired: [CodingPendingWork] { pending.filter { $0.required && $0.completedEvidence == nil } }
    public var readyForImplementation: Bool {
        clarification == nil && CodingReasoningStep.allCases.allSatisfy { discussed[$0]?.isEmpty == false }
    }
    public var sayNext: String {
        if let retry { return retry }
        if spokenQuestionArmed { return "Listening for your question. Press Ask again to cancel." }
        if let clarification { return clarification.asked == nil ? clarification.question : "Waiting for the interviewer's answer." }
        if authorizedStage == nil && readyForImplementation { return nextStage.cue }
        return stage.isImplementation ? "Explain your edit as you save it." : "Talk through the \(reasoningStep.rawValue)."
    }
    public var phase: CodingPhase {
        switch stage {
        case .understanding: .understanding
        case .reasoning: .designing
        case .simple, .hardening, .optimization: .implementing
        case .verification: .verifying
        case .concluded: .wrappingUp
        }
    }
    public mutating func restore(generation: Int, sourceRevision: String) {
        self.generation = generation; self.sourceRevision = sourceRevision
        authorizedStage = nil; authorizedPendingIDs = nil; authorization = nil; spokenQuestionArmed = false
        foregroundQuestionID = nil; questionOwners = [:]; checkedSourceRevision = nil
        // A resumed call starts a new transcript sequence space. Settled facts,
        // reasoning evidence and clarification history retain the prior context.
        transcript = []
        taskRevision += 1; stage = clarification == nil ? .reasoning : .understanding
    }
}
/// Untrusted dialogue interpretation. All evidence is rechecked by the controller's reducer.
public struct CodingDialogueUpdate: Codable, Equatable, Sendable {
    public var sessionID: String
    public var generation: Int
    public var sourceRevision: String
    public var requirementRevision: Int
    public var taskRevision: Int
    public var facts: [CodingDialogueFact]?
    public var clarification: CodingClarification?
    public var discussedSteps: [CodingReasoningStep]?
    public var discussedStep: CodingReasoningStep?
    public var evidence: [CodingDialogueEvidence]?
    public var pending: [CodingPendingWork]?
    public var pointers: [String]?
    public var limitation: String?
    public var questionToAssistant: CodingDialogueEvidence?
    public var retry: String?
    public init(state: CodingInterviewFlowState) {
        sessionID = state.sessionID; generation = state.generation; sourceRevision = state.sourceRevision
        requirementRevision = state.requirementRevision; taskRevision = state.taskRevision
    }
}

/// The publication policy is usable by the engine, restored histories and Call answers.
public enum CodingInterviewPublication {
    public static func permitsCode(_ stage: CodingInterviewStage?, flow: CodingInterviewFlowState?) -> Bool {
        guard let flow, let stage, stage.isImplementation else { return false }
        return flow.authorizedStage == stage && flow.stage == stage && flow.clarification == nil
    }
    public static func screen(_ proposed: CodingMove, flow: CodingInterviewFlowState) -> CodingMove {
        var move = proposed
        guard permitsCode(move.implementationStage, flow: flow),
              move.pendingWorkID.map({ flow.authorizedPendingIDs?.contains($0) == true }) ?? true else {
            // The file goes only when there was code to withhold. An anchor
            // beside a private proposal points at an edit the reader has not
            // been shown, so it goes with it — but a words-only step's anchor
            // is just a location, the same one the candidate is looking at in
            // their own editor, and it is what lets the panel say *where* an
            // explanation lands. Nulling it unconditionally was safe only
            // because nothing but a code step ever set it.
            if move.code != nil { move.file = nil }
            move.code = nil; move.check = nil
            if move.kind == .edit || move.kind == .implementation {
                move.kind = .design; move.say = flow.sayNext; move.why = flow.pointers.joined(separator: "\n")
            }
            move.say = prose(move.say); move.why = prose(move.why); move.watch = prose(move.watch)
            return move
        }
        return move
    }
    public static func prose(_ value: String?) -> String? {
        guard let value else { return nil }
        // A code block on an answer surface must not bypass the stage gate.
        return value.components(separatedBy: "```").enumerated().filter { $0.offset.isMultiple(of: 2) }
            .map(\.element).joined().replacingOccurrences(of: "`", with: "")
    }
}

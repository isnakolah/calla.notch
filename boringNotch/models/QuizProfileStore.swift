import CallaContracts
import Defaults
import Foundation

// `QuizModeProfile` lives in CallaContracts, which has no business depending on a
// settings library. The conformance is free — Defaults synthesises it for Codable.
extension QuizModeProfile: Defaults.Serializable {}
extension QuizModelSelection: Defaults.Serializable {}
extension QuizAnswerStrategy: Defaults.Serializable {}

/// The councils, one per question mode.
///
/// Quiz used to have exactly four models in four flat `Key<String>` entries, which
/// cannot express a roster that varies in length — let alone five of them. This
/// owns the stored shape, the defaults, and the one-time migration off the flat
/// keys so an existing setup is carried over rather than reset.
enum QuizProfileStore {
    /// Sensible starting councils: cheap and fast where agreement is easy to
    /// check, deep where the model has to compose something.
    static var factoryDefaults: [String: QuizModeProfile] {
        [
            QuizMode.choice.rawValue: QuizModeProfile(
                voters: [
                    QuizModelSelection(modelID: "gemini-3.8-flash-medium", effort: "low"),
                    QuizModelSelection(modelID: "claude-sonnet-4-6", effort: "low"),
                ],
                arbiter: QuizModelSelection(modelID: "claude-opus-4-6-thinking"),
                strategy: .majority),
            QuizMode.numeric.rawValue: QuizModeProfile(
                voters: [
                    QuizModelSelection(modelID: "gemini-3.8-flash-medium", effort: "low"),
                    QuizModelSelection(modelID: "claude-sonnet-4-6", effort: "low"),
                ],
                arbiter: QuizModelSelection(modelID: "claude-opus-4-6-thinking"),
                strategy: .unanimous),
            // Written and code answers: get something on screen fast, then let a
            // stronger model reason properly and try to beat it.
            QuizMode.open.rawValue: QuizModeProfile(
                voters: [QuizModelSelection(modelID: "claude-sonnet-4-6", effort: "medium")],
                arbiter: nil,
                strategy: .first,
                refiner: QuizModelSelection(modelID: "claude-opus-4-6-thinking", effort: "high")),
            QuizMode.visual.rawValue: QuizModeProfile(
                voters: [
                    QuizModelSelection(modelID: "gemini-3.1-pro-high"),
                    QuizModelSelection(modelID: "claude-opus-4-6-thinking"),
                ],
                arbiter: QuizModelSelection(modelID: "claude-opus-4-6-thinking"),
                strategy: .unanimous),
            QuizMode.fallback.rawValue: QuizModeProfile(
                voters: [
                    QuizModelSelection(modelID: "gemini-3.1-pro-high"),
                    QuizModelSelection(modelID: "claude-opus-4-6-thinking"),
                    QuizModelSelection(modelID: "claude-sonnet-4-6"),
                ],
                arbiter: QuizModelSelection(modelID: "claude-opus-4-6-thinking"),
                strategy: .unanimous),
        ]
    }

    /// Folds a pre-modes setup into the `fallback` council, once.
    ///
    /// Only the modes the user had no way to configure are left at their
    /// factory values; the council they actually chose becomes the fallback, so
    /// an unrecognised question is still answered the way they set it up.
    static func migrateIfNeeded() {
        guard !Defaults[.callaQuizProfilesMigrated] else { return }
        Defaults[.callaQuizProfilesMigrated] = true
        let legacy = [Defaults[.callaQuizVoterOneModel],
                      Defaults[.callaQuizVoterTwoModel],
                      Defaults[.callaQuizVoterThreeModel]]
            .filter { !$0.isEmpty }
        guard !legacy.isEmpty else { return }
        let arbiter = Defaults[.callaQuizArbiterModel]
        var profiles = Defaults[.callaQuizProfiles]
        profiles[QuizMode.fallback.rawValue] = QuizModeProfile(
            voters: legacy.map { QuizModelSelection(modelID: $0) },
            arbiter: arbiter.isEmpty ? nil : QuizModelSelection(modelID: arbiter),
            strategy: .unanimous)
        Defaults[.callaQuizProfiles] = profiles
    }

    static func profile(for mode: QuizMode) -> QuizModeProfile {
        Defaults[.callaQuizProfiles][mode.rawValue]
            ?? factoryDefaults[mode.rawValue]
            ?? QuizModeProfile(voters: [QuizModelSelection(modelID: "gemini-3.1-pro-high")])
    }

    static func setProfile(_ profile: QuizModeProfile, for mode: QuizMode) {
        var profiles = Defaults[.callaQuizProfiles]
        profiles[mode.rawValue] = profile
        Defaults[.callaQuizProfiles] = profiles
    }

    static var warmMode: QuizMode {
        QuizMode(rawValue: Defaults[.callaQuizWarmMode]) ?? .choice
    }

    /// Every model any council could ask for, which is what the Settings pane
    /// checks against the AGY catalogue.
    static var referencedModelIDs: Set<String> {
        var found = Set<String>()
        for profile in Defaults[.callaQuizProfiles].values {
            found.formUnion(profile.voters.map(\.modelID))
            if let arbiter = profile.arbiter { found.insert(arbiter.modelID) }
        }
        return found
    }
}

import XCTest
@testable import CallaContracts

final class QuizContractsTests: XCTestCase {
    private let target = QuizWindowTarget(
        processID: 42, windowID: 7, bundleID: "com.example.quiz",
        applicationName: "Browser", windowTitle: "Question 1",
        pixelWidth: 1200, pixelHeight: 800)

    private var voters: [QuizModelSelection] {
        [
            QuizModelSelection(modelID: "gemini-3.1-pro-high"),
            QuizModelSelection(modelID: "claude-opus-4-6-thinking"),
            QuizModelSelection(modelID: "claude-sonnet-4-6"),
        ]
    }

    private func configuration(voters: [QuizModelSelection],
                               profiles: [String: QuizModeProfile]? = nil) -> QuizSessionConfiguration {
        QuizSessionConfiguration(
            sessionID: "session-1234", target: target, voters: voters,
            arbiter: QuizModelSelection(modelID: "claude-opus-4-6-thinking"),
            profiles: profiles)
    }

    /// The council used to be required to be exactly three. It is now the user's
    /// to size — a single fast voter is a supported setup, not a broken one.
    func testASingleVoterIsAValidCouncil() throws {
        let one = [QuizModelSelection(modelID: "gemini-3.1-pro-high")]
        XCTAssertNoThrow(try QuizContractValidation.validate(configuration(voters: one)))
    }

    func testCouncilBoundsAreEnforcedAtBothEnds() throws {
        XCTAssertThrowsError(try QuizContractValidation.validate(configuration(voters: []))) {
            XCTAssertEqual($0 as? QuizContractValidation.Failure, .invalidModels)
        }
        let tooMany = (0 ... QuizContract.maximumVoters).map {
            QuizModelSelection(modelID: "gemini-3.1-pro-\($0)")
        }
        // The initialiser caps the roster, so the stored council is legal even
        // when more were handed in — the ceiling cannot be exceeded by accident.
        let capped = configuration(voters: tooMany)
        XCTAssertEqual(capped.voters.count, QuizContract.maximumVoters)
        XCTAssertNoThrow(try QuizContractValidation.validate(capped))
    }

    func testAnInvalidProfileFailsValidationEvenWhenTheFlatCouncilIsFine() throws {
        let broken = QuizModeProfile(voters: [QuizModelSelection(modelID: "!!")])
        XCTAssertThrowsError(try QuizContractValidation.validate(
            configuration(voters: voters, profiles: [QuizMode.open.rawValue: broken]))) {
            XCTAssertEqual($0 as? QuizContractValidation.Failure, .invalidModels)
        }
    }

    func testAProfileIsUsedForItsModeAndTheFlatCouncilIsTheFallback() {
        let solo = QuizModeProfile(
            voters: [QuizModelSelection(modelID: "gemini-3.7-flash-low", effort: "low")],
            arbiter: nil, strategy: .first)
        let value = configuration(voters: voters,
                                  profiles: [QuizMode.choice.rawValue: solo])
        XCTAssertEqual(value.profile(for: .singleChoice).voters.count, 1)
        XCTAssertEqual(value.profile(for: .singleChoice).strategy, .first)
        XCTAssertFalse(value.profile(for: .singleChoice).hasArbiter)
        // A mode with no profile falls back to the flat council.
        XCTAssertEqual(value.profile(for: .code).voters.count, 3)
        XCTAssertEqual(value.profile(for: .code).strategy, .unanimous)
    }

    func testAVersionOneConfigurationStillDecodesWithoutProfiles() throws {
        let legacy = configuration(voters: voters)
        let round = try JSONDecoder().decode(
            QuizSessionConfiguration.self, from: try JSONEncoder().encode(legacy))
        XCTAssertNil(round.profiles)
        XCTAssertNil(round.warmMode)
        XCTAssertEqual(round.effectiveWarmMode, .choice)
        // Every mode still answers, using the flat council.
        for mode in QuizMode.allCases {
            XCTAssertEqual(round.profile(for: mode).voters.count, 3)
        }
    }

    func testReferencedModelsCoverEveryProfile() {
        let solo = QuizModeProfile(voters: [QuizModelSelection(modelID: "gemini-3.7-flash-low")])
        let value = configuration(voters: voters, profiles: [QuizMode.choice.rawValue: solo])
        XCTAssertTrue(value.referencedModelIDs.contains("gemini-3.7-flash-low"))
        XCTAssertTrue(value.referencedModelIDs.contains("claude-sonnet-4-6"))
    }

    func testEveryQuestionKindMapsToAMode() {
        XCTAssertEqual(QuizMode.mode(for: .singleChoice), .choice)
        XCTAssertEqual(QuizMode.mode(for: .multipleChoice), .choice)
        XCTAssertEqual(QuizMode.mode(for: .boolean), .choice)
        XCTAssertEqual(QuizMode.mode(for: .numeric), .numeric)
        XCTAssertEqual(QuizMode.mode(for: .text), .open)
        XCTAssertEqual(QuizMode.mode(for: .code), .open)
        XCTAssertEqual(QuizMode.mode(for: .image), .visual)
        XCTAssertEqual(QuizMode.mode(for: .diagram), .visual)
        XCTAssertEqual(QuizMode.mode(for: .unknown), .fallback)
    }

    func testAgreementThresholdsMatchTheRule() {
        XCTAssertEqual(QuizAnswerStrategy.first.requiredAgreement(of: 5), 1)
        XCTAssertEqual(QuizAnswerStrategy.majority.requiredAgreement(of: 5), 3)
        XCTAssertEqual(QuizAnswerStrategy.majority.requiredAgreement(of: 4), 2)
        XCTAssertEqual(QuizAnswerStrategy.majority.requiredAgreement(of: 1), 1)
        XCTAssertEqual(QuizAnswerStrategy.unanimous.requiredAgreement(of: 5), 5)
    }

    func testConfigurationAcceptsThreeVotersAndFrozenContext() throws {
        let configuration = QuizSessionConfiguration(
            sessionID: "session-1234", target: target, eventID: "event-1234",
            eventLabel: "Biology", context: [
                QuizContextReference(id: "note-1234", revision: "revision-1",
                                     title: "Chapter notes", scope: .event,
                                     kind: "note", text: "Chlorophyll absorbs light.")
            ], voters: [
                QuizModelSelection(modelID: "gemini-3.1-pro-high"),
                QuizModelSelection(modelID: "claude-opus-4-6-thinking"),
                QuizModelSelection(modelID: "claude-sonnet-4-6"),
            ], arbiter: QuizModelSelection(modelID: "claude-opus-4-6-thinking"))
        XCTAssertNoThrow(try QuizContractValidation.validate(configuration))
    }

    func testLateEventDoesNotMatchNewGeneration() {
        let event = QuizEvent(sessionID: "session-1234", questionID: "question-1234",
                              questionGeneration: 2, sequence: 1, kind: .answer,
                              state: .answered)
        XCTAssertTrue(event.matches(sessionID: "session-1234", questionID: "question-1234", generation: 2))
        XCTAssertFalse(event.matches(sessionID: "session-1234", questionID: "question-1234", generation: 3))
    }

    func testRetryingRemainsRunningAndRoundTrips() throws {
        XCTAssertTrue(QuizSessionState.retrying.isRunning)
        let encoded = try JSONEncoder().encode(QuizSessionState.retrying)
        XCTAssertEqual(try JSONDecoder().decode(QuizSessionState.self, from: encoded), .retrying)
    }

    func testFailedAnswerAlwaysSanitizesOutput() {
        let answer = QuizFinalAnswer(sessionID: "session-1234", questionID: "question-1234",
                                     questionGeneration: 1, kind: .code,
                                     answer: "model leak", confidence: 99, verified: false)
        XCTAssertEqual(answer.answer, "Unable to verify")
        XCTAssertEqual(answer.confidence, 0)
    }

    func testRetargetRequiresTarget() {
        let command = QuizCommand(sessionID: "session-1234", command: .retarget)
        XCTAssertThrowsError(try QuizContractValidation.validate(command, activeSessionID: "session-1234"))
    }

    func testWindowSelectionKeepsCurrentExplicitTarget() {
        let other = QuizWindowTarget(
            processID: 51, windowID: 8, bundleID: "com.example.other",
            applicationName: "Other", windowTitle: "Other window",
            pixelWidth: 900, pixelHeight: 700)
        let selected = QuizWindowSelection.resolve(
            windows: [other, target], currentID: target.id,
            rememberedID: other.id, rememberedBundleID: other.bundleID,
            rememberedWindowTitle: other.windowTitle)
        XCTAssertEqual(selected, target)
    }

    func testWindowSelectionRestoresRememberedIdentityThenAppAndTitle() {
        XCTAssertEqual(QuizWindowSelection.resolve(
            windows: [target], currentID: nil, rememberedID: target.id,
            rememberedBundleID: "", rememberedWindowTitle: ""), target)

        let relaunched = QuizWindowTarget(
            processID: 99, windowID: 88, bundleID: target.bundleID,
            applicationName: target.applicationName, windowTitle: target.windowTitle,
            pixelWidth: target.pixelWidth, pixelHeight: target.pixelHeight)
        XCTAssertEqual(QuizWindowSelection.resolve(
            windows: [relaunched], currentID: nil, rememberedID: target.id,
            rememberedBundleID: target.bundleID,
            rememberedWindowTitle: target.windowTitle), relaunched)
    }

    func testWindowSelectionNeverDefaultsToFirstWindow() {
        XCTAssertNil(QuizWindowSelection.resolve(
            windows: [target], currentID: nil, rememberedID: "",
            rememberedBundleID: "", rememberedWindowTitle: ""))
    }

    func testCaptureResolutionPresetsFormCommonAscendingLadder() {
        XCTAssertEqual(QuizCaptureResolution.allCases.map(\.label),
                       ["720p", "900p", "1080p", "2K", "1440p", "4K", "5K", "6K", "8K"])
        XCTAssertEqual(QuizCaptureResolution.allCases.map(\.maximumWidth),
                       [1_280, 1_600, 1_920, 2_048, 2_560, 3_840, 5_120, 6_016, 7_680])
        XCTAssertEqual(QuizCaptureResolution.allCases.map(\.maximumHeight),
                       [720, 900, 1_080, 1_080, 1_440, 2_160, 2_880, 3_384, 4_320])
    }

    func testConfigurationFreezesSelectedCaptureResolution() throws {
        let configuration = QuizSessionConfiguration(
            sessionID: "session-1234", target: target, voters: voters,
            arbiter: QuizModelSelection(modelID: "claude-opus-4-6-thinking"),
            captureResolution: .fourK)
        XCTAssertEqual(configuration.effectiveCaptureResolution, .fourK)
        XCTAssertNoThrow(try QuizContractValidation.validate(configuration))
    }

    func testLegacyVersionOneConfigurationUsesDefaultCaptureResolution() throws {
        let configuration = QuizSessionConfiguration(
            sessionID: "session-1234", target: target, voters: voters,
            arbiter: QuizModelSelection(modelID: "claude-opus-4-6-thinking"))
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any])
        object.removeValue(forKey: "captureResolution")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(QuizSessionConfiguration.self, from: legacyData)
        XCTAssertEqual(decoded.effectiveCaptureResolution, QuizContract.defaultCaptureResolution)
        XCTAssertNoThrow(try QuizContractValidation.validate(decoded))
    }
    // MARK: - Warming

    func testAWarmRequestCarriesACouncilAndNothingElse() throws {
        // Warming spawns processes before there is a session, so what it can
        // carry is the point: no target, no session identifier, no context. The
        // encoded form is the proof — a field that is not here cannot be sent.
        let request = QuizWarmRequest(
            mode: .choice,
            profile: QuizModeProfile(voters: [QuizModelSelection(modelID: "gemini-3.7-flash-low")],
                                     arbiter: nil, strategy: .majority))
        XCTAssertNoThrow(try QuizContractValidation.validate(request))
        let encoded = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(request)) as? [String: Any]
        XCTAssertEqual(Set(encoded?.keys ?? [:].keys).sorted(),
                       ["contractVersion", "mode", "profile"])
    }

    func testAWarmRequestWithNoVotersIsRejected() {
        let request = QuizWarmRequest(
            mode: .choice,
            profile: QuizModeProfile(voters: [], arbiter: nil, strategy: .majority))
        XCTAssertThrowsError(try QuizContractValidation.validate(request)) {
            XCTAssertEqual($0 as? QuizContractValidation.Failure, .invalidModels)
        }
    }

    func testAWarmRequestFromAnotherContractVersionIsRejected() {
        let request = QuizWarmRequest(
            mode: .choice,
            profile: QuizModeProfile(voters: [QuizModelSelection(modelID: "model")],
                                     arbiter: nil, strategy: .majority),
            contractVersion: QuizContract.version + 1)
        XCTAssertThrowsError(try QuizContractValidation.validate(request)) {
            XCTAssertEqual($0 as? QuizContractValidation.Failure, .wrongVersion)
        }
    }

    func testAWarmRequestRoundTrips() throws {
        let request = QuizWarmRequest(
            mode: .open,
            profile: QuizModeProfile(voters: [QuizModelSelection(modelID: "claude-sonnet-4-6")],
                                     arbiter: nil, strategy: .first,
                                     refiner: QuizModelSelection(modelID: "claude-opus-4-6-thinking")))
        let decoded = try JSONDecoder().decode(
            QuizWarmRequest.self, from: try JSONEncoder().encode(request))
        XCTAssertEqual(decoded, request)
    }

}

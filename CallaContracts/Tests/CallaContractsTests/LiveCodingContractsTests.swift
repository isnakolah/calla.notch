import XCTest
@testable import CallaContracts

/// Contract v2 additions: the clock, rubric coverage, move provenance, and the
/// tolerant decoding that keeps a session sealed under v1 loadable.
final class LiveCodingContractsV2Tests: XCTestCase {

    func testSelectedWindowIdentitySurvivesCommandAndOldCommandsCanOmitIt() throws {
        var command = CodingCommand(sessionID: "session-1234", callID: "call-123456", generation: 2, kind: .selectWindow)
        command.observationTarget = QuizWindowTarget(processID: 123, windowID: 456,
            bundleID: "com.microsoft.VSCode", applicationName: "Code", windowTitle: "Project", pixelWidth: 900, pixelHeight: 600)
        XCTAssertEqual(try JSONDecoder().decode(CodingCommand.self, from: JSONEncoder().encode(command)), command)
        command.observationTarget = nil
        command.kind = .requestMove
        XCTAssertNil(try JSONDecoder().decode(CodingCommand.self, from: JSONEncoder().encode(command)).observationTarget)
    }

    func testTranscriptAnchorSurvivesRoundTripAndOlderCommandsStillDecode() throws {
        let command = CodingCommand(sessionID: "session-1234", callID: "call-123456",
                                    generation: 2, kind: .requestMove,
                                    transcript: "What about duplicate keys?", speaker: .them,
                                    transcriptSequence: 42)
        let data = try JSONEncoder().encode(command)
        XCTAssertEqual(try JSONDecoder().decode(CodingCommand.self, from: data).transcriptSequence, 42)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "transcriptSequence")
        let older = try JSONSerialization.data(withJSONObject: object)
        XCTAssertNil(try JSONDecoder().decode(CodingCommand.self, from: older).transcriptSequence)
    }


    /// A v1 record must still decode.
    ///
    /// Version is enforced by `LiveCodingValidation`, which can only run on a
    /// value that decoded. If the bump made old JSON throw, a sealed session
    /// would vanish from History instead of being reported as out of date —
    /// silently, because `retainedSessions()` maps over `try?`.
    func testASessionSealedUnderV1StillDecodes() throws {
        let v1 = """
        {"contractVersion":1,"sessionID":"session-1234","callID":"call-123456",
         "generation":2,"folderCapabilityID":"folder-12345","provider":"local",
         "model":"gemini-3.1-pro-high","retainUntilDeleted":true,
         "networkPolicy":{"commandsMayUseNetwork":true,"discloseRemoteAgent":true}}
        """
        let decoded = try JSONDecoder().decode(
            CodingSessionConfiguration.self, from: Data(v1.utf8))
        XCTAssertEqual(decoded.sessionID, "session-1234")
        XCTAssertNil(decoded.plannedDurationMinutes)
        XCTAssertEqual(decoded.contractVersion, 1)
        XCTAssertThrowsError(try LiveCodingValidation.validate(decoded)) {
            XCTAssertEqual($0 as? LiveCodingValidation.Failure, .wrongVersion)
        }
    }

    func testAMoveSealedUnderV1DecodesAsAnUnprioritisedModelClaim() throws {
        let v1 = """
        {"id":"move-1","ordinal":1,"sourceRevision":"abc","kind":"design",
         "status":"current","createdAt":0,"updatedAt":0}
        """
        let decoded = try JSONDecoder().decode(CodingMove.self, from: Data(v1.utf8))
        XCTAssertEqual(decoded.origin, .model)
        XCTAssertEqual(decoded.priority, .advisory)
        XCTAssertTrue(decoded.rubricIDs.isEmpty)
        XCTAssertNil(decoded.confidence)
    }

    func testSnapshotSealedUnderV1DecodesWithEmptyCoverage() throws {
        let v1 = """
        {"contractVersion":1,"generation":0,"lifecycle":"finished",
         "syncState":"unavailable","phase":"understanding","latestSequence":-1}
        """
        let decoded = try JSONDecoder().decode(CodingSessionSnapshot.self, from: Data(v1.utf8))
        XCTAssertTrue(decoded.rubric.isEmpty)
        XCTAssertNil(decoded.remainingSeconds)
        XCTAssertNil(decoded.attribution)
    }

    func testBriefItemIDsAreStableAndCoverEverySection() {
        let brief = InterviewBrief(
            source: .text, title: "Sliding window maximum",
            rubric: ["state complexity", "explain the deque invariant"],
            constraints: ["no external libraries"],
            taskOrdering: ["correctness first"],
            suppliedInterfaces: ["solve(nums, k)"],
            depriorities: ["input validation"])
        let items = brief.items
        XCTAssertEqual(items.count, 6)
        XCTAssertEqual(items.map(\.id).first, "rubric-0")
        XCTAssertEqual(Set(items.map(\.id)).count, items.count)
        XCTAssertEqual(items.map(\.id), brief.items.map(\.id))
        XCTAssertEqual(items.last?.kind, .deprioritised)
        XCTAssertEqual(items.first(where: { $0.kind == .suppliedInterface })?.text,
                       "solve(nums, k)")
    }

    /// A model that returns 150 must not be able to display 150.
    func testMoveConfidenceIsClampedToAPercentage() {
        XCTAssertEqual(CodingMove(ordinal: 1, sourceRevision: "a", kind: .design,
                                  confidence: 150).confidence, 100)
        XCTAssertEqual(CodingMove(ordinal: 1, sourceRevision: "a", kind: .design,
                                  confidence: -20).confidence, 0)
    }

    func testTurnTimingSurvivesTheWire() throws {
        let command = CodingCommand(sessionID: "session-1234", callID: "call-123456",
                                    generation: 2, kind: .requestMove,
                                    transcript: "so I would use a deque here",
                                    speaker: .me, confidence: 0.9, t0: 12.25, t1: 14.5)
        let decoded = try JSONDecoder().decode(
            CodingCommand.self, from: JSONEncoder().encode(command))
        XCTAssertEqual(decoded.t0, 12.25)
        XCTAssertEqual(decoded.t1, 14.5)
    }
}

final class LiveCodingContractsTests: XCTestCase {
    private let configuration = CodingSessionConfiguration(
        sessionID: "session-1234", callID: "call-123456", generation: 2,
        folderCapabilityID: "folder-12345")

    func testConfigurationRoundTripsAndValidates() throws {
        try LiveCodingValidation.validate(configuration)
        let decoded = try JSONDecoder().decode(
            CodingSessionConfiguration.self, from: JSONEncoder().encode(configuration))
        XCTAssertEqual(decoded, configuration)
    }

    func testRejectsWrongVersionAndUnboundedBrief() throws {
        var wrong = configuration
        wrong.contractVersion += 1
        XCTAssertThrowsError(try LiveCodingValidation.validate(wrong)) {
            XCTAssertEqual($0 as? LiveCodingValidation.Failure, .wrongVersion)
        }
        var huge = configuration
        huge.brief = InterviewBrief(source: .text, title: "brief",
                                    rubric: [String(repeating: "x", count: LiveCodingContract.maximumBriefBytes + 1)])
        XCTAssertThrowsError(try LiveCodingValidation.validate(huge)) {
            XCTAssertEqual($0 as? LiveCodingValidation.Failure, .tooLarge)
        }
    }

    func testSnapshotRejectsStaleOrForeignEvents() {
        let snapshot = CodingSessionSnapshot(
            sessionID: configuration.sessionID, callID: configuration.callID,
            generation: configuration.generation, lifecycle: .capturing, latestSequence: 4)
        XCTAssertTrue(snapshot.accepts(CodingEvent(
            sessionID: configuration.sessionID, callID: configuration.callID,
            generation: configuration.generation, sequence: 5, kind: .move)))
        XCTAssertFalse(snapshot.accepts(CodingEvent(
            sessionID: configuration.sessionID, callID: configuration.callID,
            generation: configuration.generation, sequence: 4, kind: .move)))
        XCTAssertFalse(snapshot.accepts(CodingEvent(
            sessionID: "session-other", callID: configuration.callID,
            generation: configuration.generation, sequence: 6, kind: .move)))
    }

    func testRelativePathsCannotEscapeShadow() {
        XCTAssertNoThrow(try LiveCodingValidation.validate(relativePath: "Sources/Parser.swift"))
        XCTAssertThrowsError(try LiveCodingValidation.validate(relativePath: "../secret"))
        XCTAssertThrowsError(try LiveCodingValidation.validate(relativePath: "/Users/me/secret"))
    }

    func testCommandMustMatchExactCallGeneration() {
        let snapshot = CodingSessionSnapshot(
            sessionID: configuration.sessionID, callID: configuration.callID,
            generation: configuration.generation, lifecycle: .capturing)
        let accepted = CodingCommand(sessionID: configuration.sessionID,
                                     callID: configuration.callID,
                                     generation: configuration.generation,
                                     kind: .requestMove, transcript: "Use recursion",
                                     speaker: .me, confidence: 0.96)
        XCTAssertNoThrow(try LiveCodingValidation.validate(accepted, against: snapshot))
        var stale = accepted
        stale.generation -= 1
        XCTAssertThrowsError(try LiveCodingValidation.validate(stale, against: snapshot))
    }
}

/// The date-format mismatch that made Live Coding time out on start.
///
/// The engine decodes app→engine payloads with `.iso8601`, but the app encoded
/// them with a plain `JSONEncoder`, which writes a `Date` as a number. The
/// decoder throws on that rather than coercing, the throw was swallowed by a
/// `try?`, and the notch sat out its 45-second timer reporting "Live Coding did
/// not start in time" — with nothing anywhere naming a date.
final class LiveCodingWireFormatTests: XCTestCase {
    private var isoEncoder: JSONEncoder {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; return encoder
    }
    private var isoDecoder: JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder
    }

    private var configuration: CodingSessionConfiguration {
        CodingSessionConfiguration(
            sessionID: "code-1234abcd", callID: "call-123456", generation: 1,
            folderCapabilityID: "folder-12345",
            brief: InterviewBrief(source: .text, title: "Spreadsheet engine",
                                  rubric: ["simple, extensible design"]),
            plannedDurationMinutes: 60)
    }

    func testTheConfigurationSurvivesTheRealWire() throws {
        let decoded = try isoDecoder.decode(
            CodingSessionConfiguration.self, from: isoEncoder.encode(configuration))
        XCTAssertEqual(decoded.sessionID, configuration.sessionID)
        XCTAssertEqual(decoded.plannedDurationMinutes, 60)
        XCTAssertEqual(decoded.brief?.title, "Spreadsheet engine")
    }

    /// The actual failure. If this ever stops throwing, the two coders have been
    /// reconciled some other way and `engineEncoder` is no longer load-bearing.
    func testAPlainEncoderIsRejectedByTheEnginesISO8601Decoder() throws {
        let plain = try JSONEncoder().encode(configuration)
        XCTAssertThrowsError(
            try isoDecoder.decode(CodingSessionConfiguration.self, from: plain))
    }

    /// It was already broken before `startedAt` existed: any brief carries
    /// `frozenAt`, so a configured interview never got past this.
    func testABriefAloneIsEnoughToTripIt() throws {
        var withoutClock = configuration
        withoutClock.plannedDurationMinutes = nil
        let plain = try JSONEncoder().encode(withoutClock)
        XCTAssertThrowsError(
            try isoDecoder.decode(CodingSessionConfiguration.self, from: plain))
    }

    func testCommandsCrossCleanlyInBothFormats() throws {
        let command = CodingCommand(sessionID: "code-1234abcd", callID: "call-123456",
                                    generation: 1, kind: .requestMove,
                                    transcript: "let me start with the parser",
                                    speaker: .me, confidence: 0.9, t0: 1, t1: 2)
        XCTAssertNoThrow(try isoDecoder.decode(CodingCommand.self,
                                               from: isoEncoder.encode(command)))
    }
}

/// Per-lane model control, and the activity the panel reports.
final class LiveCodingProfileTests: XCTestCase {
    /// The three lanes want opposite things; one model for all of them is how
    /// the move lane ended up on the pro tier while the candidate waited.
    func testTheDefaultProfilePutsTheWaitedOnLaneOnTheFastestModel() {
        let profile = CodingModelProfile.standard
        XCTAssertEqual(profile.move.modelID, "gemini-3.8-flash-low")
        XCTAssertEqual(profile.move.effort, "low")
        XCTAssertEqual(profile.edit.modelID, "gemini-3.1-pro-high")
        XCTAssertEqual(profile.edit.effort, "high")
        XCTAssertNotEqual(profile.move.modelID, profile.edit.modelID)
    }

    func testTheConfigurationCarriesTheProfileOverTheWire() throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let chosen = CodingModelProfile(
            move: .init(modelID: "gemini-3.7-flash-medium", effort: "medium"),
            plan: .init(modelID: "gemini-3.1-pro-high", effort: "high"),
            edit: .init(modelID: "gemini-3.1-pro-high", effort: "high"))
        let configuration = CodingSessionConfiguration(
            sessionID: "code-1234abcd", callID: "call-123456", generation: 1,
            folderCapabilityID: "folder-12345", profile: chosen)
        let decoded = try decoder.decode(CodingSessionConfiguration.self,
                                         from: encoder.encode(configuration))
        XCTAssertEqual(decoded.profile, chosen)
    }

    /// A session sealed before the profile existed must still open.
    func testAConfigurationWithoutAProfileFallsBackToTheStandardOne() throws {
        let old = """
        {"contractVersion":2,"sessionID":"code-1234abcd","callID":"call-123456",
         "generation":1,"folderCapabilityID":"folder-12345","provider":"local",
         "model":"gemini-3.7-flash-low","retainUntilDeleted":true,
         "networkPolicy":{"commandsMayUseNetwork":true,"discloseRemoteAgent":true}}
        """
        let decoded = try JSONDecoder().decode(
            CodingSessionConfiguration.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.profile, .standard)
    }

    /// A deliberately quiet twin must not look like a dead one.
    func testSilenceIsAReportableActivity() {
        var snapshot = CodingSessionSnapshot(sessionID: "s", callID: "c", generation: 1)
        XCTAssertEqual(snapshot.activity, .preparing)
        snapshot.activity = .silent
        snapshot.activityDetail = "candidate is fluent"
        XCTAssertEqual(snapshot.activity, .silent)
        XCTAssertNotEqual(snapshot.activity, .blocked)
    }

    func testASnapshotSealedBeforeActivityExistedStillDecodes() throws {
        let old = """
        {"contractVersion":2,"generation":0,"lifecycle":"finished",
         "syncState":"unavailable","phase":"understanding","latestSequence":-1}
        """
        let decoded = try JSONDecoder().decode(CodingSessionSnapshot.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.activity, .preparing)
        XCTAssertNil(decoded.activityDetail)
    }
}

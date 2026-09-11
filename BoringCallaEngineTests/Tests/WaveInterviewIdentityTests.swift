import Foundation
import Testing
@testable import CallaNotchPresentation

/// The interview's identity is a constant rather than a calendar lookup, which
/// is the whole reason a session started today and a session started on Monday
/// are sessions of the same meeting. These pin the values every scope, every
/// call row and every knowledge note is keyed on.
struct WaveInterviewIdentityTests {
    @Test func identityIsStableAndDistinct() {
        // Changing either of these silently re-homes every note filed against
        // the interview and orphans the sessions already recorded under it.
        #expect(WaveInterview.seriesID == "wave-interview")
        #expect(WaveInterview.eventID == "wave-interview-2026-09-07")
        #expect(WaveInterview.seriesID != WaveInterview.eventID)
    }

    @Test func identifiersSurviveTheEngineValidator() {
        // The engine refuses an identifier it cannot put in a prompt: bounded,
        // and free of control characters. A synthetic id has to clear the same
        // bar as one from EventKit.
        for identifier in [WaveInterview.seriesID, WaveInterview.eventID] {
            #expect(!identifier.isEmpty)
            #expect(identifier.count <= 256)
            #expect(!identifier.unicodeScalars.contains {
                $0.properties.generalCategory == .control
            })
        }
    }

    @Test func theSittingIsMondayNoonInNairobi() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Africa/Nairobi"))
        let start = calendar.dateComponents([.year, .month, .day, .hour, .minute],
                                            from: WaveInterview.startsAt)
        #expect(start.year == 2026)
        #expect(start.month == 9)
        #expect(start.day == 7)
        #expect(start.hour == 12)
        #expect(start.minute == 0)
        // Two hours, which is what the session's planned duration is derived from.
        #expect(WaveInterview.endsAt.timeIntervalSince(WaveInterview.startsAt) == 2 * 60 * 60)
        #expect(WaveInterview.plannedMinutes == 120)
    }

    @Test func materialIsFiledAgainstEverySessionNotOneSitting() {
        // Series, not event. An event-scoped setup would apply to one sitting,
        // and a rehearsal is a different session of the same meeting.
        #expect(WaveInterview.setupScope == "series")
        #expect(WaveInterview.setupScopeKey == WaveInterview.seriesID)
    }

    @Test func theCallRunsOnTheInterviewPersona() {
        // `live/personas/interview.md` exists; `generic` was the old default and
        // is the wrong guidance for this call.
        #expect(WaveInterview.persona == "interview")
        #expect(WaveInterview.profileID == "wave")
    }
}

/// Testing today is the only way to know any of this works tomorrow, so a
/// rehearsal has to be a full run of the real thing — same meeting, same
/// preparation — that still cannot be mistaken for the sitting afterwards.
struct WaveSessionKindTests {
    @Test func bothRunsAreSessionsOfOneMeeting() {
        // Same series is what makes the prepared project, the brief and the
        // attached material reach a rehearsal unchanged.
        #expect(WaveInterview.Session.rehearsal.eventID == WaveInterview.rehearsalEventID)
        #expect(WaveInterview.Session.sitting.eventID == WaveInterview.eventID)
        #expect(WaveInterview.Session.rehearsal.eventID != WaveInterview.Session.sitting.eventID)
    }

    @Test func anUnknownStoredValueIsARehearsal() {
        // Wrong towards practice costs nothing; wrong towards the sitting files
        // practice conclusions where the real session will read them.
        #expect(WaveInterview.Session.stored("rehearsal") == .rehearsal)
        #expect(WaveInterview.Session.stored("sitting") == .sitting)
        #expect(WaveInterview.Session.stored("") == .rehearsal)
        #expect(WaveInterview.Session.stored("nonsense") == .rehearsal)
    }

    @Test func eachRunSaysWhichItIs() {
        #expect(WaveInterview.Session.rehearsal.isRehearsal)
        #expect(!WaveInterview.Session.sitting.isRehearsal)
        // The chip is the one glance that answers "am I about to record the
        // real thing", so the two must never read the same.
        #expect(WaveInterview.Session.rehearsal.chipTitle
                != WaveInterview.Session.sitting.chipTitle)
    }
}

struct CallaModeTests {
    @Test func theOldCodeModeFoldsOntoTheInterview() {
        // Call and Code both drew the interview before they merged; `code` has
        // no surface of its own any more.
        #expect(CallaMode.stored("code") == .interview)
    }

    @Test func realModesRoundTripAndAnythingElseIsSafe() {
        #expect(CallaMode.stored("interview") == .interview)
        #expect(CallaMode.stored("call") == .call)
        #expect(CallaMode.stored("quiz") == .quiz)
        #expect(CallaMode.stored("") == .interview)
        #expect(CallaMode.stored("nonsense") == .interview)
    }

    @Test func liveCallIsAlwaysAvailableAndCodingIsHidden() {
        #expect(!CallaFeatureAvailability.liveCoding)
        for plainCall in [false, true] {
            #expect(CallaMode.available(plainCall: plainCall, quiz: false) == [.call])
            #expect(CallaMode.available(plainCall: plainCall, quiz: true) == [.call, .quiz])
        }
    }

    @Test func legacySelectionsResolveToCallWithoutChangingTheirIdentity() {
        for raw in ["code", "interview", "call", "", "nonsense"] {
            for plainCall in [false, true] {
                #expect(CallaMode.resolved(raw, plainCall: plainCall, quiz: true) == .call)
                #expect(CallaMode.resolved(raw, plainCall: plainCall, quiz: false) == .call)
            }
        }
        #expect(CallaMode.stored("code") == .interview)
        #expect(CallaMode.stored("interview") == .interview)
        #expect(CallaMode.resolved("quiz", plainCall: false, quiz: false) == .call)
        #expect(CallaMode.resolved("quiz", plainCall: false, quiz: true) == .quiz)
    }
}

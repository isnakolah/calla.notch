//
//  CallaCodingSetup.swift
//  boringNotch
//
//  Everything a Live Coding session needs, decided before the interview starts.
//
//  Code used to ask for all of it in the notch, thirty seconds before a call:
//  choose a folder from an `NSOpenPanel`, type or load a brief, read a
//  three-line disclosure, then press Start. That is four decisions and a file
//  picker on a 100pt surface, and the surface could not hold them — the buttons
//  were drawn through the notch's lower curve. It is also the wrong moment: the
//  project and the brief are known the day the interview is booked, not while
//  the interviewer is waiting on the line.
//
//  So the setup moves to where the rest of a meeting's preparation already
//  lives — the Knowledge pane, attached to the meeting or its series, exactly
//  like a note or a briefing document. The notch then has one job: name what it
//  resolved, and offer Start.
//
//  Resolution is narrowest-first: this occurrence, then the series, then the
//  fallback that applies when no meeting is chosen. Same order the copilot's
//  knowledge already uses, so a reader who has learned one has learned both.
//
//  The folder is kept as an **app-scoped security bookmark**. A capability
//  minted by the engine (`CodingFolderPreflight.capabilityID`) lives only in
//  that XPC process and dies with it, so it cannot be what "set up beforehand"
//  means — the bookmark is the durable half, and the capability is minted from
//  it at Start.
//

import CallaContracts
import Defaults
import Foundation

/// One project, one brief, filed against one meeting.
struct CallaCodingSetup: Codable, Equatable, Identifiable, Defaults.Serializable {
    /// `always`, `event` or `series` — the same vocabulary knowledge notes use.
    var scope: String
    /// The event id or series id. Absent for `always`.
    var scopeKey: String?

    /// App-scoped security bookmark for the project folder.
    var folderBookmark: Data?
    /// What to call it before the bookmark has been resolved. Resolving one is
    /// cheap but not free, and this surface is drawn on every poll.
    var folderName: String
    /// Shown so the reader can tell two folders named `src` apart.
    var folderPath: String

    /// What the interview is, in the brief the model is given.
    var briefTitle: String
    /// `text`, `file` or `url`.
    var briefSource: String
    /// What the interviewer is grading.
    var rubric: [String]
    /// Rules the candidate has been given.
    var constraints: [String]
    /// The order the task is meant to be attacked in.
    var taskOrdering: [String]
    /// Parsers, harnesses and interfaces that are provided rather than written.
    var suppliedInterfaces: [String]
    /// Explicitly not worth time.
    var depriorities: [String]

    var interviewProfile: String?
    var observationTarget: QuizWindowTarget?
    var updatedAt: Date

    var id: String { "\(scope):\(scopeKey ?? "-")" }

    init(scope: String,
         scopeKey: String? = nil,
         folderBookmark: Data? = nil,
         folderName: String = "",
         folderPath: String = "",
         briefTitle: String = "",
         briefSource: String = "text",
         rubric: [String] = [],
         constraints: [String] = [],
         taskOrdering: [String] = [],
         suppliedInterfaces: [String] = [],
         depriorities: [String] = [],
         updatedAt: Date = Date()) {
        self.scope = scope
        self.scopeKey = scopeKey
        self.folderBookmark = folderBookmark
        self.folderName = folderName
        self.folderPath = folderPath
        self.briefTitle = briefTitle
        self.briefSource = briefSource
        self.rubric = rubric
        self.constraints = constraints
        self.taskOrdering = taskOrdering
        self.suppliedInterfaces = suppliedInterfaces
        self.depriorities = depriorities
        self.updatedAt = updatedAt
    }

    var hasFolder: Bool { folderBookmark != nil && !folderName.isEmpty }

    /// Whether anything has been written into the brief yet.
    var hasBrief: Bool {
        !briefTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !rubric.isEmpty || !constraints.isEmpty || !taskOrdering.isEmpty
            || !suppliedInterfaces.isEmpty || !depriorities.isEmpty
    }

    /// Fills the brief in from the published spec, if nothing has been written.
    ///
    /// These fields used to start empty with a placeholder, which meant typing
    /// out — from the spec, by hand, correctly — the one thing the app already
    /// knows verbatim. Everything below is quoted from
    /// `https://wavemm.github.io/spreadsheet-split/python_part2`; the pack's
    /// `spec.md` carries the same facts in full.
    ///
    /// Only ever applied to an empty brief. Someone who wrote their own reading
    /// of the rubric meant it, and having it silently replaced by the
    /// boilerplate would be worse than an empty box.
    mutating func applyPublishedBriefIfEmpty() {
        guard !hasBrief else { return }
        briefTitle = "Wave, part 2 — spreadsheet formula evaluation"
        // The interviewer's own stack ranking, in their order.
        rubric = [
            "High quality design — clean components, well-specified interfaces",
            "User-friendly details — the edge cases the spec leaves vague on purpose",
            "Speed — completing every task beats polishing one",
        ]
        // The published recommended order, which is also the task ladder.
        taskOrdering = [
            "Cell references, =A1",
            "Literal numbers and dates",
            "Binary operators + - * / on numbers",
            "sum, with ranges and several arguments",
            "Binary operators on dates, if time",
            "sqrt, if time",
        ]
        suppliedInterfaces = [
            "sheet.formula.parse — no leading =, string for a leaf, list for an operator or call",
            "sheet.formula.ParseError",
            "sheet.models.Range — inclusive first/last, parse, contains, height, width, indices, row(i)",
            "sheet.models.Index — parse, row/col, labels, +, max, min",
            "part2.bundle, merged with git pull --no-rebase",
        ]
        // Stated as "don't worry about" in the spec.
        depriorities = [
            "A unit-test suite — keep the code testable, but do not build one",
            "Docstrings, naming, comment polish",
            "Trivial bugs and regressions",
            "Performance, unless an operation exceeds one second",
            "Security",
        ]
        constraints = [
            "Spaces required on both sides of a binary operator",
            "Function names are alphanumeric, case-insensitive, any number of arguments",
            "Ranges are inclusive; reversed endpoints normalise",
            "A circular reference must not hang or crash",
            "Dates: + and - only; date + number is a date, date - date is days, date + date invalid",
            "Logging goes to spreadsheet.log — print() is swallowed by the curses UI",
        ]
    }

    /// Whether anything was actually written down. An empty row is deleted
    /// rather than stored: a setup that names nothing would still resolve, and
    /// would then shadow the fallback with a blank.
    var isEmpty: Bool {
        !hasFolder && briefTitle.isEmpty && rubric.isEmpty && constraints.isEmpty
            && taskOrdering.isEmpty && suppliedInterfaces.isEmpty && depriorities.isEmpty
            && interviewProfile == nil && observationTarget == nil
    }

    /// Said in the second person, because that is who is reading it.
    var scopeLabel: String {
        switch scope {
        case "event": "This meeting"
        case "series": "This meeting and every repeat"
        default: "Any Code session"
        }
    }

    /// The brief as the engine wants it, or nil when nothing was written down.
    /// A nil brief is a legitimate state — the model then works from the
    /// transcript and the project alone.
    var brief: InterviewBrief? {
        let title = briefTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty || !rubric.isEmpty || !taskOrdering.isEmpty
                || !constraints.isEmpty || !suppliedInterfaces.isEmpty
                || !depriorities.isEmpty else { return nil }
        return InterviewBrief(
            source: CodingBriefSourceKind(rawValue: briefSource) ?? .text,
            title: title.isEmpty ? "Interview" : title,
            rubric: rubric,
            constraints: constraints,
            taskOrdering: taskOrdering,
            suppliedInterfaces: suppliedInterfaces,
            depriorities: depriorities)
    }

    /// "main · Swift · 412 files", as far as it can be known without touching
    /// the disk. The live facts — branch, dirty, size — arrive with the engine's
    /// preflight once the folder has been registered.
    var folderSummary: String {
        guard hasFolder else { return "" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if folderPath.hasPrefix(home) {
            return "~" + folderPath.dropFirst(home.count)
        }
        return folderPath
    }
}

/// Where the setups are kept, and how the right one is found.
@MainActor
final class CallaCodingSetupStore: ObservableObject {
    static let shared = CallaCodingSetupStore()

    @Published private(set) var setups: [CallaCodingSetup] = []

    private init() {
        setups = Defaults[.callaCodingSetups]
        if CallaFeatureAvailability.liveCoding { adoptExistingSetupIfNeeded() }
    }

    /// Brings a project prepared before the interview became the only meeting
    /// into the interview's own scope.
    ///
    /// Setups used to be filed against whichever calendar event they were
    /// prepared for. Once the notch stopped resolving a meeting from the
    /// calendar, a setup filed that way became unreachable — the folder, the
    /// brief, the rubric and the task order were all still on disk, and the
    /// notch said "No project set up yet". Copied rather than moved, so the
    /// original row survives if this guessed wrong, and run once.
    private func adoptExistingSetupIfNeeded() {
        guard !Defaults[.callaWaveSetupAdopted] else { return }
        Defaults[.callaWaveSetupAdopted] = true
        guard setup(scope: WaveInterview.setupScope,
                    scopeKey: WaveInterview.setupScopeKey) == nil else { return }
        // The most recently prepared one that actually names a folder. A row
        // with only a window target in it is not a project.
        guard let candidate = setups.filter(\.hasFolder).max(by: { $0.updatedAt < $1.updatedAt })
        else { return }
        var adopted = candidate
        adopted.scope = WaveInterview.setupScope
        adopted.scopeKey = WaveInterview.setupScopeKey
        adopted.applyPublishedBriefIfEmpty()
        save(adopted)
    }

    // MARK: - Reading

    func setup(scope: String, scopeKey: String?) -> CallaCodingSetup? {
        setups.first { $0.scope == scope && $0.scopeKey == scopeKey }
    }

    /// The fallback: what a Code session uses when it is not tied to a meeting.
    var fallback: CallaCodingSetup? {
        setup(scope: "always", scopeKey: nil)
    }

    /// The setup that applies to one meeting, narrowest first.
    ///
    /// Occurrence beats series beats fallback. A candidate who prepared one
    /// specific round of a repeating interview loop should get that round's
    /// project, not the one the loop usually uses.
    func setup(eventID: String?, seriesID: String?) -> CallaCodingSetup? {
        if let eventID, let match = setup(scope: "event", scopeKey: eventID) { return match }
        if let seriesID, let match = setup(scope: "series", scopeKey: seriesID) { return match }
        return fallback
    }

    func setup(for event: EventModel) -> CallaCodingSetup? {
        setup(eventID: event.id, seriesID: event.seriesID)
    }

    /// Whether this meeting has a setup of its own, as opposed to inheriting the
    /// fallback. Drives the calendar's "prepared" marks, where inheriting is not
    /// the same as being prepared.
    func hasOwnSetup(for event: EventModel) -> Bool {
        if setup(scope: "event", scopeKey: event.id) != nil { return true }
        if let seriesID = event.seriesID, setup(scope: "series", scopeKey: seriesID) != nil { return true }
        return false
    }

    // MARK: - Writing

    func save(_ setup: CallaCodingSetup) {
        var next = setups.filter { $0.id != setup.id }
        if !setup.isEmpty {
            var stored = setup
            stored.updatedAt = Date()
            next.append(stored)
        }
        next.sort { $0.id < $1.id }
        setups = next
        Defaults[.callaCodingSetups] = next
    }

    func remove(scope: String, scopeKey: String?) {
        let id = "\(scope):\(scopeKey ?? "-")"
        let next = setups.filter { $0.id != id }
        guard next.count != setups.count else { return }
        setups = next
        Defaults[.callaCodingSetups] = next
    }

    /// Mints an app-scoped bookmark for a folder the user has just chosen.
    ///
    /// Returns nil rather than throwing: every caller's recovery is the same —
    /// say the folder could not be kept and leave the previous one in place.
    func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [.withSecurityScope],
                              includingResourceValuesForKeys: nil,
                              relativeTo: nil)
    }

    /// Resolves a stored bookmark back to a folder, refreshing it when the OS
    /// says it has gone stale — a folder that was renamed or moved still
    /// resolves, and the refreshed bookmark is written back so it keeps doing so.
    ///
    /// The caller owns the security scope: this starts it, and hands back a
    /// closer that must be run when the folder is no longer needed. Registering
    /// a folder with the engine copies what it needs synchronously, so in
    /// practice that is the end of the same call.
    func resolveFolder(_ setup: CallaCodingSetup) -> (url: URL, release: () -> Void)? {
        guard let bookmark = setup.folderBookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark,
                                 options: [.withSecurityScope],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        let accessing = url.startAccessingSecurityScopedResource()
        if stale {
            var refreshed = setup
            refreshed.folderBookmark = self.bookmark(for: url)
            refreshed.folderPath = url.path
            refreshed.folderName = url.lastPathComponent
            if refreshed.folderBookmark != nil { save(refreshed) }
        }
        return (url, { if accessing { url.stopAccessingSecurityScopedResource() } })
    }
}


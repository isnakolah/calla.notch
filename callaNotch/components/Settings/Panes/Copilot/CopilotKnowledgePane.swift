import Defaults
import SwiftUI
import UniformTypeIdentifiers

/// Everything the copilot can be given something for, browsable like the rest of
/// System Settings.
///
/// A list of *meetings* rather than a list of notes, and it includes meetings with
/// nothing attached — those are the ones you came here to fix, and a list that
/// only showed prepared meetings would hide exactly the rows worth opening.
/// Picking one pushes its own page, so the surface stays a browser and the
/// editing happens somewhere with room for it.
struct CopilotKnowledgePane: View {
    @StateObject private var library = CallaKnowledgeLibrary.shared
    @ObservedObject private var calendarManager = CalendarManager.shared
    @ObservedObject private var categories = MeetingCategoryStore.shared
    /// Observed so a project attached on a meeting's page shows up in this list
    /// the moment it is saved, rather than on the next navigation.
    @ObservedObject private var focus = CallaKnowledgeFocus.shared

    @Environment(\.settingsRouter) private var router
    @Default(.callaCarryRecaps) private var carryRecaps
    @State private var search = ""
    @State private var month = Calendar.current.startOfDay(for: Date())
    @State private var selectedDay: Date?
    @State private var loaded = false

    var body: some View {
        root
            .task {
                guard !loaded else { return }
                loaded = true
                await library.load()
                await calendarManager.refreshCallMeetings()
                // Arriving from the calendar's right-click: open that meeting
                // rather than making someone find it again in a month of events.
                if let eventID = focus.eventID {
                    router?.push(.copilotKnowledgeDetail(.event(id: eventID)))
                    focus.clearFocus()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .callaKnowledgeDidChange)) { _ in
                Task { await library.load() }
            }
    }

    /// In the order people reach for it: what Calla always has, the meetings
    /// that repeat and carry their recaps forward, what is coming up, and then
    /// every meeting, for the one that is none of those.
    private var root: some View {
        SettingsPane(.knowledge) {
            overview
            everywhereCard
            repeatingCard
            upcomingCallsCard
            carryCard
            meetingsCard
            if !library.orphanedNotes.isEmpty { orphanCard }
        }
    }

    // MARK: - Meetings that repeat

    /// One card per repeating meeting in range, soonest first: each one's
    /// recaps go into the next call when "Carry recaps forward" is on.
    private var repeatingMeetings: [EventModel] {
        var seen = Set<String>()
        return library.events
            .filter { $0.hasRecurrenceRules && ($0.seriesID?.isEmpty == false) && $0.end > Date() }
            .sorted { $0.start < $1.start }
            .filter { seen.insert($0.seriesID ?? $0.id).inserted }
    }

    @ViewBuilder
    private var repeatingCard: some View {
        let meetings = Array(repeatingMeetings.prefix(6))
        if !meetings.isEmpty {
            SettingCard("Meetings that repeat",
                        detail: carryRecaps ? "Calla adds each call's recap to the next one." : "Each call starts without the last one's recap.") {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(meetings) { event in
                        Button {
                            router?.push(.copilotKnowledgeDetail(.event(id: event.id)))
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Image(systemName: "repeat").font(.system(size: 11)).foregroundStyle(.secondary)
                                    Text(event.title).font(NotchType.rowTitle).lineLimit(1)
                                }
                                Text("Next \(event.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))")
                                    .font(NotchType.rowDetail).foregroundStyle(.secondary).lineLimit(1)
                                HStack(spacing: 6) {
                                    let calls = library.callCount(for: event)
                                    if calls > 0 { tag("\(calls) recap\(calls == 1 ? "" : "s")") }
                                    let notes = library.notes(for: event).count
                                    if notes > 0 { tag("\(notes) note\(notes == 1 ? "" : "s")") }
                                    if calls == 0 && notes == 0 { tag("Nothing yet") }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.primary.opacity(0.05)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
    }

    // MARK: - Carrying recaps

    private var carryCard: some View {
        SettingsList {
            SettingsToggleRow("Carry recaps forward",
                              detail: "When a meeting repeats, the last recaps are added to the next call automatically.",
                              isOn: $carryRecaps)
        }
        .settingsAnchor("knowledge.carry")
    }

    // MARK: - Overview

    private var upcomingCallsCard: some View {
        SettingCard("Coming up", detail: "Just for one call, then kept with it in Past calls.") {
            if calendarManager.upcomingCallMeetings.isEmpty {
                Text("No upcoming linked meetings")
                    .font(NotchType.rowDetail).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(calendarManager.upcomingCallMeetings) { event in
                        Button {
                            router?.push(.copilotKnowledgeDetail(.event(id: event.id)))
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.title).font(NotchType.rowTitle)
                                    Text([event.start.formatted(date: .abbreviated, time: .shortened),
                                          CallaCopilotPersona.title(categories.confirmed(for: event)
                                              ?? categories.suggestion(for: event) ?? "generic")]
                                        .joined(separator: " · "))
                                        .font(NotchType.rowDetail).foregroundStyle(.secondary)
                                    let attached = library.notes(for: event)
                                    if attached.isEmpty {
                                        Text(event.hasRecurrenceRules && carryRecaps
                                             ? "Nothing added. Calla will use the last recap."
                                             : "Nothing added.")
                                            .font(NotchType.rowDetail).foregroundStyle(.tertiary)
                                    } else {
                                        HStack(spacing: 6) {
                                            ForEach(attached.prefix(3)) { note in
                                                tag(note.title.isEmpty ? "Untitled" : note.title)
                                            }
                                            if attached.count > 3 { tag("+\(attached.count - 3)") }
                                        }
                                    }
                                }
                                Spacer()
                                Text("Add").font(NotchType.rowDetail).foregroundStyle(Color.accentColor)
                                Image(systemName: "chevron.right").font(.caption)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 7)
                        Divider()
                    }
                }
            }
        }
    }

    private var overview: some View {
        SettingCard {
            HStack(alignment: .top, spacing: 22) {
                figure("\(library.notes.filter(\.isDocument).count)", "file\(library.notes.filter(\.isDocument).count == 1 ? "" : "s")")
                figure("\(library.notes.filter { !$0.isDocument }.count)", "note\(library.notes.filter { !$0.isDocument }.count == 1 ? "" : "s")")
                figure("\(library.preparedEvents.count)", "meeting\(library.preparedEvents.count == 1 ? "" : "s") prepared")
                Spacer(minLength: 8)
                TextField("Search meetings and files", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                Button("Add") { router?.push(.copilotKnowledgeDetail(.everyCall)) }
                    .buttonStyle(.borderedProminent)
                    .help("Add a file or a note for every call. To add one for a single meeting, choose it below or drop the file on the notch.")
            }
        }
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(size: 22, weight: .semibold).monospacedDigit())
            Text(label).font(NotchType.rowDetail).foregroundStyle(.secondary)
        }
    }

    // MARK: - Not tied to a meeting

    private var everywhereCard: some View {
        SettingCard("Every call", detail: "Background Calla always has, whatever the meeting.") {
            VStack(spacing: 0) {
                ForEach(library.notes(scope: "always").prefix(5)) { note in
                    HStack(spacing: 10) {
                        Image(systemName: note.symbol)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(note.title.isEmpty ? "Untitled note" : note.title).font(NotchType.rowTitle).lineLimit(1)
                            Text(note.subtitle).font(NotchType.rowDetail).foregroundStyle(.tertiary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Button("Edit") { router?.push(.copilotKnowledgeDetail(.everyCall)) }
                            .controlSize(.small)
                    }
                    .padding(.vertical, 6)
                    Divider().padding(.leading, 32)
                }
                navigationRow(
                    route: .everyCall,
                    symbol: "globe",
                    title: "Every call",
                    detail: "Calla has these on every call",
                    count: library.notes(scope: "always").count)
                Divider().padding(.leading, 32)
                navigationRow(
                    route: .byPersona,
                    symbol: "theatermasks",
                    title: "Notes for one kind of call",
                    detail: "For example, a pitch deck only for sales calls",
                    count: library.notes(scope: "persona").count)
            }
        }
    }

    // MARK: - Meetings

    private var meetingsCard: some View {
        SettingCard("Meetings", detail: meetingsDetail) {
            KnowledgeCalendar(month: $month,
                              selectedDay: $selectedDay,
                              index: library.dayIndex(for: month))
                .task(id: month) { await library.ensureLoaded(month: month) }

            Divider().opacity(0.35).padding(.vertical, NotchSpace.tight)

            if library.isLoading && library.events.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading your calendar…").font(NotchType.rowDetail).foregroundStyle(.secondary)
                }
            } else if let day = selectedDay {
                let events = library.events(on: day)
                if events.isEmpty {
                    SettingsEmptyState(
                        symbol: "calendar.badge.minus",
                        title: "Nothing on \(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))",
                        detail: "Pick another day, or clear the selection to see the whole range.",
                        actionTitle: "Show everything",
                        action: { withAnimation(NotchMotion.settle) { selectedDay = nil } })
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                            eventRow(event)
                            if index < events.count - 1 {
                                Divider().padding(.leading, 32)
                            }
                        }
                    }
                }
            } else {
                let groups = library.groupedByDay(matching: search)
                if groups.isEmpty {
                    Text(search.isEmpty
                         ? "Nothing to show."
                         : "No meeting matches “\(search)”.")
                        .font(NotchType.rowDetail)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 14) {
                        ForEach(groups, id: \.day) { group in
                            VStack(spacing: 0) {
                                HStack {
                                    Text(dayLabel(group.day))
                                        .font(.system(size: 10, weight: .bold))
                                        .tracking(0.7)
                                        .foregroundStyle(.tertiary)
                                    Spacer(minLength: 0)
                                }
                                .padding(.bottom, 5)

                                ForEach(Array(group.events.enumerated()), id: \.element.id) { index, event in
                                    eventRow(event)
                                    if index < group.events.count - 1 {
                                        Divider().padding(.leading, 32)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// What the card says it is showing, which changes with the selection.
    private var meetingsDetail: String {
        if let day = selectedDay {
            return day.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
        }
        return library.events.isEmpty
            ? "No meetings in the last week or the next month."
            : "The last week and the next month, or pick a day above. A repeating meeting shares whatever is attached to the series."
    }

    private func eventRow(_ event: EventModel) -> some View {
        let attached = library.notes(for: event)
        let calls = library.callCount(for: event)
        return navigationRow(
            route: .event(id: event.id),
            symbol: event.seriesID != nil && event.hasRecurrenceRules ? "repeat" : "calendar",
            title: event.title,
            detail: [
                event.start.formatted(date: .omitted, time: .shortened),
                calls > 0 ? "\(calls) call\(calls == 1 ? "" : "s")" : nil,
                event.videoCallURL != nil ? "has a call link" : nil,
            ].compactMap { $0 }.joined(separator: " · "),
            count: attached.count,
            documents: attached.filter(\.isDocument).count)
    }

    /// One tappable row that pushes a page. Deliberately the same shape for a
    /// meeting and for the two catch-alls, so the list reads as one thing.
    private func navigationRow(
        route: KnowledgeRoute,
        symbol: String,
        title: String,
        detail: String,
        count: Int,
        documents: Int = 0
    ) -> some View {
        Button {
            router?.push(.copilotKnowledgeDetail(route))
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(count > 0 ? Color.accentColor : .secondary)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(NotchType.rowTitle).lineLimit(1)
                    Text(detail).font(NotchType.rowDetail).foregroundStyle(.tertiary).lineLimit(1)
                }

                Spacer(minLength: 8)

                if count > 0 {
                    HStack(spacing: 4) {
                        if documents > 0 {
                            Image(systemName: "paperclip").font(.system(size: 9, weight: .bold))
                        }
                        Text("\(count)")
                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Orphans

    private var orphanCard: some View {
        SettingCard(
            "Not on your calendar any more",
            detail: "These are attached to a meeting that has been deleted, or whose occurrences have all passed. They still apply if it comes back.",
            tint: NotchTint.attention
        ) {
            navigationRow(
                route: .orphaned,
                symbol: "questionmark.folder",
                title: "Unmatched",
                detail: "Review or remove",
                count: library.orphanedNotes.count,
                documents: library.orphanedNotes.filter(\.isDocument).count)
        }
    }

    private func dayLabel(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "TODAY" }
        if calendar.isDateInTomorrow(day) { return "TOMORROW" }
        if calendar.isDateInYesterday(day) { return "YESTERDAY" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE d MMMM"
        return formatter.string(from: day).uppercased()
    }
}

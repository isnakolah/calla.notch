//
//  CalendarManager.swift
//  callaNotch
//
//  Created by Harsh Vardhan  Goswami  on 08/09/24.
//

import AppKit
import Defaults
import EventKit
import SwiftUI
import CallaContracts
import CryptoKit

// MARK: - CalendarManager

@MainActor
class CalendarManager: ObservableObject {
    static let shared = CalendarManager()

    @Published var currentWeekStartDate: Date
    @Published var events: [EventModel] = []
    @Published var allCalendars: [CalendarModel] = []
    @Published var eventCalendars: [CalendarModel] = []
    @Published var reminderLists: [CalendarModel] = []
    @Published var selectedCalendarIDs: Set<String> = []
    @Published var calendarAuthorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published var reminderAuthorizationStatus: EKAuthorizationStatus = .notDetermined
    private var selectedCalendars: [CalendarModel] = []
    private let calendarService = CalendarService()

    private var eventStoreChangedObserver: NSObjectProtocol?
    private var appBecameActiveObserver: NSObjectProtocol?
    @Published private(set) var callMeetings: [EventModel] = []
    @Published private(set) var upcomingCallMeetings: [EventModel] = []
    @Published private(set) var selectedCallMeeting: EventModel?
    private var explicitlySelectedCallMeetingID: String?
    private var callWatchTask: Task<Void, Never>?
    private var offeredCallOccurrences = Set<String>()
    private var dismissedCallOccurrences = Set<String>()

    private init() {
        self.currentWeekStartDate = CalendarManager.startOfDay(Date())
        setupEventStoreChangedObserver()
        Task {
            await reloadCalendarAndReminderLists()
        }
    }

    deinit {
        if let observer = eventStoreChangedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = appBecameActiveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func setupEventStoreChangedObserver() {
        eventStoreChangedObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task {
                await self?.reloadCalendarAndReminderLists()
                await self?.refreshCallMeetings()
            }
        }
        appBecameActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { await self?.refreshCallMeetings() }
        }
    }

    @MainActor
    func reloadCalendarAndReminderLists() async {
        let all = await calendarService.calendars()
        self.eventCalendars = all.filter { !$0.isReminder }
        self.reminderLists = all.filter { $0.isReminder }
        self.allCalendars = all // for legacy compatibility, can be removed if not needed
        updateSelectedCalendars()
    }

    /// A calendar offer never starts capture. The app opens this surface once
    /// per occurrence and the reader explicitly starts the call from it.
    func startCallWatch() {
        guard callWatchTask == nil else { return }
        callWatchTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.refreshCallMeetings()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func refreshCallMeetings() async {
        guard Defaults[.callaCopilotEnabled], !Defaults[.calendarCallAccountIDs].isEmpty else {
            callMeetings = []
            upcomingCallMeetings = []
            if selectedCallMeeting?.id != explicitlySelectedCallMeetingID
                || (selectedCallMeeting?.end ?? .distantPast) <= Date() {
                explicitlySelectedCallMeetingID = nil
                selectedCallMeeting = nil
            }
            return
        }
        let selected = Array(selectedCalendarIDs)
        let fetched = await calendarService.upcoming(within: 30 * 24 * 60 * 60, calendars: selected)
        let now = Date()
        let enabledAccounts = Set(Defaults[.calendarCallAccountIDs])
        let upcoming = fetched.filter { event in
            event.type.isEvent && !event.isAllDay && event.attendance != .declined
                && event.videoCallURL != nil && event.end > now
                && enabledAccounts.contains(event.calendar.accountID)
                && selectedCalendarIDs.contains(event.calendar.id)
        }.sorted { $0.start < $1.start }
        upcomingCallMeetings = upcoming
        MeetingCategoryStore.shared.prepare(upcoming)
        let eligible = upcoming.filter {
            $0.start <= now.addingTimeInterval(CalendarCallPolicy.leadTime)
                && !dismissedCallOccurrences.contains($0.id)
        }
        callMeetings = eligible
        let engine = CallaEngineClient.shared
        if !engine.callPresentationProtected {
            if let selectedCallMeeting, eligible.contains(where: { $0.id == selectedCallMeeting.id }) {
                self.selectedCallMeeting = eligible.first { $0.id == selectedCallMeeting.id }
            } else if let id = explicitlySelectedCallMeetingID,
                      let event = fetched.first(where: { $0.id == id && $0.end > now && $0.videoCallURL != nil }) {
                selectedCallMeeting = event
            } else {
                explicitlySelectedCallMeetingID = nil
                selectedCallMeeting = eligible.first
            }
        }
        guard let event = selectedCallMeeting,
              !offeredCallOccurrences.contains(event.id),
              !engine.callPresentationProtected,
              !engine.status.copilot.running,
              !engine.callIsComingUp,
              !engine.callIsFinishing,
              !engine.status.quiz.active else { return }
        NSLog("[CallaCalendar] offering meeting occurrence=%@", event.id)
        NotificationCenter.default.post(name: .callaMeetingWantsNotch, object: nil)
    }

    func markCallMeetingPresented() {
        guard let event = selectedCallMeeting else { return }
        offeredCallOccurrences.insert(event.id)
    }

    func selectCallMeeting(_ event: EventModel) {
        guard event.videoCallURL != nil, event.end > Date() else { return }
        explicitlySelectedCallMeetingID = event.id
        selectedCallMeeting = event
    }

    /// Whether the reader waved this occurrence away in the get-ready panel.
    func callMeetingDismissed(_ id: String) -> Bool {
        dismissedCallOccurrences.contains(id)
    }

    func dismissCallMeeting() {
        guard let event = selectedCallMeeting else { return }
        explicitlySelectedCallMeetingID = nil
        dismissedCallOccurrences.insert(event.id)
        callMeetings.removeAll { $0.id == event.id }
        selectedCallMeeting = callMeetings.first
    }

    func checkCalendarAuthorization() async {
        let status = EKEventStore.authorizationStatus(for: .event)
        DispatchQueue.main.async {
            print("📅 Current calendar authorization status: \(status)")
            self.calendarAuthorizationStatus = status
        }

        switch status {
        case .notDetermined:
            guard let granted = try? await calendarService.requestAccess(to: .event) else {
                self.calendarAuthorizationStatus = .notDetermined
                return
            }
            self.calendarAuthorizationStatus = granted ? .fullAccess : .denied
            if granted {
                await reloadCalendarAndReminderLists()
                events = await calendarService.events(
                    from: currentWeekStartDate,
                    to: Calendar.current.date(byAdding: .day, value: 1, to: currentWeekStartDate)!,
                    calendars: selectedCalendars.map { $0.id })
            }
        case .restricted, .denied:
            NSLog("Calendar access denied or restricted")
        case .fullAccess:
            NSLog("Full access")
            await reloadCalendarAndReminderLists()
            events = await calendarService.events(
                from: currentWeekStartDate,
                to: Calendar.current.date(byAdding: .day, value: 1, to: currentWeekStartDate)!,
                calendars: selectedCalendars.map { $0.id })
        case .writeOnly:
            NSLog("Write only")
        @unknown default:
            print("Unknown authorization status")
        }
    }
    
    func checkReminderAuthorization() async {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        DispatchQueue.main.async {
            print("📅 Current reminder authorization status: \(status)")
            self.reminderAuthorizationStatus = status
        }

        switch status {
        case .notDetermined:
            guard let granted = try? await calendarService.requestAccess(to: .reminder) else {
                self.reminderAuthorizationStatus = .notDetermined
                return
            }
            self.reminderAuthorizationStatus = granted ? .fullAccess : .denied
            if granted {
                await reloadCalendarAndReminderLists()
            }
        case .restricted, .denied:
            NSLog("Reminder access denied or restricted")
        case .fullAccess:
            NSLog("Full access")
            await reloadCalendarAndReminderLists()
        case .writeOnly:
            NSLog("Write only")
        @unknown default:
            print("Unknown authorization status")
        }
    }
        

    func updateSelectedCalendars() {
        // Populate selectedCalendarIDs based on Defaults calendar selection state
        switch Defaults[.calendarSelectionState] {
        case .all:
            selectedCalendarIDs = Set(allCalendars.map { $0.id })
        case .selected(let identifiers):
            selectedCalendarIDs = identifiers
        }

        // Update the local calendar objects that correspond to the selected ids
        selectedCalendars = allCalendars.filter { selectedCalendarIDs.contains($0.id) }
    }

    func getCalendarSelected(_ calendar: CalendarModel) -> Bool {
        return selectedCalendarIDs.contains(calendar.id)
    }

    func setCalendarSelected(_ calendar: CalendarModel, isSelected: Bool) async {
        var selectionState = Defaults[.calendarSelectionState]

        switch selectionState {
        case .all:
            if !isSelected {
                let identifiers = Set(allCalendars.map { $0.id }).subtracting([calendar.id])
                selectionState = .selected(identifiers)
            }

        case .selected(var identifiers):
            if isSelected {
                identifiers.insert(calendar.id)
            } else {
                identifiers.remove(calendar.id)
            }

            selectionState =
                identifiers.isEmpty
                ? .all : identifiers.count == allCalendars.count ? .all : .selected(identifiers)  // if empty, select all
        }

        Defaults[.calendarSelectionState] = selectionState
        updateSelectedCalendars()
        await updateEvents()
        await refreshCallMeetings()
    }

    static func startOfDay(_ date: Date) -> Date {
        return Calendar.current.startOfDay(for: date)
    }

    func updateCurrentDate(_ date: Date) async {
        currentWeekStartDate = Calendar.current.startOfDay(for: date)
        await updateEvents()
    }

    private func updateEvents() async {
        let calendarIDs = selectedCalendars.map { $0.id }
        let eventsResult = await calendarService.events(
            from: currentWeekStartDate,
            to: Calendar.current.date(byAdding: .day, value: 1, to: currentWeekStartDate)!,
            calendars: calendarIDs
        )
        self.events = eventsResult
    }
    
    func setReminderCompleted(reminderID: String, completed: Bool) async {
        await calendarService.setReminderCompleted(reminderID: reminderID, completed: completed)
        // Refresh events after updating
        events = await calendarService.events(
            from: currentWeekStartDate,
            to: Calendar.current.date(byAdding: .day, value: 1, to: currentWeekStartDate)!,
            calendars: selectedCalendars.map { $0.id })
    }
}

/// A suggestion is cached before the call; only a confirmed value controls capture.
/// Occurrence choices take precedence over the recurring series.
@MainActor
final class MeetingCategoryStore: ObservableObject {
    static let shared = MeetingCategoryStore()

    private struct Choice: Codable {
        var confirmed: String?
        var suggested: String?
        var fingerprint: String?
        var attemptedAt: Date?
    }

    @Published private(set) var revision = 0
    private var choices: [String: Choice]
    private var pending = Set<String>()
    private let storageKey = "calla.meetingCategories.v1"

    private init() {
        choices = (UserDefaults.standard.data(forKey: storageKey)
            .flatMap { try? JSONDecoder().decode([String: Choice].self, from: $0) }) ?? [:]
    }

    private func seriesKey(_ event: EventModel) -> String? {
        guard event.hasRecurrenceRules, let id = event.seriesID, !id.isEmpty else { return nil }
        return "series:\(id)"
    }

    private func eventKey(_ event: EventModel) -> String { "event:\(event.id)" }

    func confirmed(for event: EventModel) -> String? {
        confirmed(eventID: event.id,
                  seriesID: seriesKey(event).map { String($0.dropFirst("series:".count)) })
    }

    func confirmed(eventID: String?, seriesID: String?) -> String? {
        (eventID.flatMap { choices["event:\($0)"]?.confirmed })
            ?? (seriesID.flatMap { choices["series:\($0)"]?.confirmed })
    }

    func suggestion(for event: EventModel) -> String? {
        choices[eventKey(event)]?.suggested
            ?? seriesKey(event).flatMap { choices[$0]?.suggested }
            ?? CalendarCallPolicy.suggestedPersona(for: event.title)
    }

    func save(_ persona: String, for event: EventModel, occurrenceOnly: Bool = false) {
        save(persona, eventID: event.id, seriesID: seriesKey(event).map { String($0.dropFirst("series:".count)) },
             occurrenceOnly: occurrenceOnly)
    }

    func save(_ persona: String, eventID: String, seriesID: String?, occurrenceOnly: Bool = false) {
        guard CallaCopilotPersona.all(including: Array(Defaults[.callaCopilotCustomPersonas].keys))
            .contains(persona) else { return }
        let key = !occurrenceOnly && seriesID?.isEmpty == false
            ? "series:\(seriesID!)" : "event:\(eventID)"
        var choice = choices[key] ?? Choice()
        guard choice.confirmed != persona else { return }
        choice.confirmed = persona
        choices[key] = choice
        persist()
        let excluded = choices.compactMap { key, value -> String? in
            guard key.hasPrefix("event:"), value.confirmed != nil else { return nil }
            return String(key.dropFirst("event:".count))
        }
        CallaEngineClient.shared.recategorizeMeeting(eventID: eventID, seriesID: seriesID,
            persona: persona, occurrenceOnly: occurrenceOnly, excluding: excluded)
    }

    func prepare(_ events: [EventModel]) {
        // Bound background model work. The next few meetings are the ones most
        // likely to be started, while later events are revisited on each refresh.
        var seen = Set<String>()
        for event in events.prefix(12) where confirmed(for: event) == nil {
            let key = seriesKey(event) ?? eventKey(event)
            guard seen.insert(key).inserted else { continue }
            let details = [event.title, event.participants.map(\.name).joined(separator: ", "),
                           event.location ?? "", event.notes ?? ""].joined(separator: "\n")
            let fingerprint = SHA256.hash(data: Data(details.utf8)).map { String(format: "%02x", $0) }.joined()
            guard !pending.contains(key) else { continue }
            if choices[key]?.fingerprint == fingerprint { continue }
            if let choice = choices[key], choice.fingerprint == nil,
               let attempted = choice.attemptedAt, Date().timeIntervalSince(attempted) < 6 * 3600 { continue }
            guard pending.count < 2 else { break }
            pending.insert(key)
            Task { [weak self] in
                await self?.classify(event, key: key, details: details, fingerprint: fingerprint)
            }
        }
    }

    private func classify(_ event: EventModel, key: String, details: String, fingerprint: String) async {
        defer { pending.remove(key) }
        let guess = await withCheckedContinuation { continuation in
            CallaEngineClient.shared.suggestMeetingCategory(details: String(details.prefix(4_000))) {
                continuation.resume(returning: $0)
            }
        }
        // Do not overwrite a choice made while the model was answering.
        guard choices[key]?.confirmed == nil else { return }
        let normalized = guess?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var choice = choices[key] ?? Choice()
        choice.suggested = normalized.flatMap { CallaPersonaCatalog.builtIn.contains($0) ? $0 : nil }
            ?? CalendarCallPolicy.suggestedPersona(for: event.title)
        choice.attemptedAt = Date()
        // A failed model request can be retried on the next calendar refresh.
        choice.fingerprint = guess == nil ? nil : fingerprint
        choices[key] = choice
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(choices) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
        revision &+= 1
    }
}

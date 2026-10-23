//
//  CalendarPane.swift
//  callaNotch
//
//  Moved out of SettingsView.swift. That file had grown to 2076 lines holding
//  eleven panes and an XPC subsystem, while every newer pane already lived in
//  its own file under Panes/.
//

import Defaults
import SwiftUI

struct CalendarSettings: View {
    private struct Account: Identifiable {
        let id: String
        let title: String
    }
    @ObservedObject private var calendarManager = CalendarManager.shared
    @Default(.showCalendar) var showCalendar: Bool
    @Default(.hideCompletedReminders) var hideCompletedReminders
    @Default(.hideAllDayEvents) var hideAllDayEvents
    @Default(.autoScrollToNextEvent) var autoScrollToNextEvent

    @Default(.showFullEventTitles) private var showFullEventTitles
    @Default(.openMeetingsInApp) private var openMeetingsInApp
    @Default(.calendarCallAccountIDs) private var callAccountIDs
    @Default(.calendarDefaultCallPersona) private var defaultCallPersona
    @Default(.callaCopilotCustomPersonas) private var customPersonas

    var body: some View {
        SettingsPane(.calendar, isOn: $showCalendar) {
            SettingCard("Display") {
                VStack(spacing: 12) {
                    SettingRow("Hide all-day events") {
                        Toggle("", isOn: $hideAllDayEvents).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Hide completed reminders") {
                        Toggle("", isOn: $hideCompletedReminders).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Scroll to the next event") {
                        Toggle("", isOn: $autoScrollToNextEvent).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Always show full titles",
                               detail: "Off truncates a long title to one line.") {
                        Toggle("", isOn: $showFullEventTitles).labelsHidden().toggleStyle(.switch)
                    }
                    SettingRow("Open meetings in their own app",
                               detail: "Off opens the meeting link in your browser.") {
                        Toggle("", isOn: $openMeetingsInApp).labelsHidden().toggleStyle(.switch)
                    }
                }
            }

            .settingsAnchor("calendar.display")

            SettingCard("Calendar calls") {
                VStack(spacing: 12) {
                    SettingRow("Default call type",
                               detail: "Used when a meeting title has no clear suggestion.") {
                        Picker("Default call type", selection: $defaultCallPersona) {
                            ForEach(CallaCopilotPersona.all(including: Array(customPersonas.keys)), id: \.self) { id in
                                Text(CallaCopilotPersona.title(id)).tag(id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                    }
                    ForEach(accountGroups, id: \.id) { account in
                        SettingRow(account.title,
                                   detail: "Show a meeting countdown and offer to start Calla.") {
                            Toggle("", isOn: Binding(
                                get: { callAccountIDs.contains(account.id) },
                                set: { enabled in
                                    var ids = Set(callAccountIDs)
                                    if enabled { ids.insert(account.id) } else { ids.remove(account.id) }
                                    callAccountIDs = ids.sorted()
                                    Task { await calendarManager.refreshCallMeetings() }
                                }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                        }
                    }
                }
            }

            SettingsEmbedded(.calendarSources) { CalendarSourcesPane() }
        }
        .task { await calendarManager.checkCalendarAuthorization() }
    }

    private var accountGroups: [Account] {
        Dictionary(grouping: calendarManager.eventCalendars, by: \.accountID)
            .map { id, calendars in
                Account(id: id, title: calendars.first?.account ?? "Calendar account")
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}

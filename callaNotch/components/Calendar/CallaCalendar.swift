//
//  CallaCalendar.swift
//  callaNotch
//
//  Created by Harsh Vardhan  Goswami  on 08/09/24.
//

import Defaults
import SwiftUI

struct Config: Equatable {
    //    var count: Int = 10  // 3 days past + today + 7 days future
    var past: Int = 7
    var future: Int = 14
    var steps: Int = 1  // Each step is one day
    var spacing: CGFloat = 0
    var showsText: Bool = true
    var offset: Int = 2  // Number of dates to the left of the selected date
}

enum WheelPickerStyle {
    case dots   // compact day-dot indicators
    case plate  // full-width date cards (weekday + numeral + month) that page horizontally
}

struct WheelPicker: View {
    @EnvironmentObject var vm: CallaViewModel
    @Binding var selectedDate: Date
    @State private var scrollPosition: Int?
    @State private var haptics: Bool = false
    @State private var byClick: Bool = false
    let config: Config
    var style: WheelPickerStyle = .dots
    var plateHeight: CGFloat = 82

    // Plate cards are full-width and self-center, so they need no edge spacers.
    private var spacerNum: Int { style == .dots ? config.offset : 0 }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: config.spacing) {
                let dateCount = totalDateItems()
                let totalItems = dateCount + 2 * spacerNum
                ForEach(0..<totalItems, id: \.self) { index in
                    if index < spacerNum || index >= spacerNum + dateCount {
                        // Leading/trailing spacers sized to match a dot cell
                        Spacer()
                            .frame(width: 16, height: 20)
                            .id(index)
                    } else {
                        let date = dateForItemIndex(index: index, spacerNum: spacerNum)
                        let isSelected = Calendar.current.isDate(date, inSameDayAs: selectedDate)
                        switch style {
                        case .dots:
                            dotButton(date: date, isSelected: isSelected, id: index) {
                                selectedDate = date
                                byClick = true
                                withAnimation {
                                    scrollPosition = index
                                }
                                if Defaults[.enableHaptics] {
                                    haptics.toggle()
                                }
                            }
                        case .plate:
                            plateCard(date: date, id: index)
                        }
                    }
                }
            }
            .frame(height: style == .dots ? 20 : plateHeight)
            .scrollTargetLayout()
        }
        .scrollIndicators(.never)
        .scrollPosition(id: $scrollPosition, anchor: .center)
        .scrollTargetBehavior(.viewAligned)  // Ensures scroll view snaps the centered view
        .safeAreaPadding(style == .dots ? .horizontal : [])
        .sensoryFeedback(.alignment, trigger: haptics)
        .onChange(of: scrollPosition) { oldValue, newValue in
            if !byClick {
                handleScrollChange(newValue: newValue, config: config)
            } else {
                byClick = false
            }
        }
        .onAppear {
            scrollToToday(config: config)
        }
        // When parent updates the bound selectedDate (e.g., view reopen), center the wheel on it
        .onChange(of: selectedDate) { _, newValue in
            let targetIndex = indexForDate(newValue)
            if scrollPosition != targetIndex {
                byClick = true
                withAnimation {
                    scrollPosition = targetIndex
                }
            }
        }
    }

    // A single day rendered as a tappable dot, on a 20pt-tall target. The
    // selected day widens into a 20pt Home pill; today (when not selected) reads
    // brighter than the rest.
    private func dotButton(
        date: Date, isSelected: Bool, id: Int, onClick: @escaping () -> Void
    ) -> some View {
        let isToday = Calendar.current.isDateInToday(date)
        let dotColor: Color = isSelected
            ? NotchAccent.home
            : isToday ? NotchInk.tertiary : Color.white.opacity(0.26)
        return Button(action: onClick) {
            Capsule(style: .continuous)
                .fill(dotColor)
                .frame(width: isSelected ? 20 : 7, height: 7)
                .frame(width: isSelected ? 28 : 16, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .help(Text(date, format: .dateTime.weekday(.wide).day().month(.wide)))
        .accessibilityLabel(Text(date, format: .dateTime.weekday(.wide).day().month(.wide)))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .id(id)
    }

    // Full-width date card used by `.plate` style: weekday, big numeral, month/year.
    @ViewBuilder
    private func plateCard(date: Date, id: Int) -> some View {
        VStack(alignment: .center, spacing: 0) {
            Text(date.formatted(.dateTime.weekday(.wide)))
                .font(.system(size: 10, weight: .bold))
                .tracking(notchCapsTracking)
                .textCase(.uppercase)
                .foregroundColor(NotchAccent.home)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text("\(date.date)")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()
                .tracking(-0.5)
                .foregroundColor(NotchInk.primary)
            Text(date.formatted(.dateTime.month(.abbreviated).year()))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(NotchInk.secondary)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity)
        .frame(height: plateHeight)
        .containerRelativeFrame(.horizontal)
        .id(id)
    }

    func handleScrollChange(newValue: Int?, config: Config) {
        guard let newIndex = newValue else { return }
        let dateCount = totalDateItems()
        guard (spacerNum..<(spacerNum + dateCount)).contains(newIndex) else { return }
        let date = dateForItemIndex(index: newIndex, spacerNum: spacerNum)
        if !Calendar.current.isDate(date, inSameDayAs: selectedDate) {
            selectedDate = date
            if Defaults[.enableHaptics] {
                haptics.toggle()
            }
        }
    }

    private func scrollToToday(config: Config) {
        let today = Date()
        byClick = true
        scrollPosition = indexForDate(today)
        selectedDate = today
    }

    // MARK: - Index/Date mapping with steps and spacers
    private func indexForDate(_ date: Date) -> Int {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let startDate = cal.startOfDay(for: cal.date(byAdding: .day, value: -config.past, to: today) ?? today)
        let target = cal.startOfDay(for: date)
        let days = cal.dateComponents([.day], from: startDate, to: target).day ?? 0
        let stepIndex = max(0, min(days / max(config.steps, 1), totalDateItems() - 1))
        return spacerNum + stepIndex
    }

    private func dateForItemIndex(index: Int, spacerNum: Int) -> Date {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let startDate = cal.date(byAdding: .day, value: -config.past, to: today) ?? today
        let stepIndex = index - spacerNum
        return cal.date(byAdding: .day, value: stepIndex * max(config.steps, 1), to: startDate) ?? today
    }

    private func totalDateItems() -> Int {
        let range = config.past + config.future
        let step = max(config.steps, 1)
        return Int(ceil(Double(range) / Double(step))) + 1
    }
}

struct CalendarView: View {
    @EnvironmentObject var vm: CallaViewModel
    @ObservedObject private var calendarManager = CalendarManager.shared
    @State private var selectedDate = Date()

    // "Today hero" date plate: the big date (weekday + numeral + month/year) is a
    // horizontally scrollable pager — scroll/swipe it to move between days — with a
    // row of day-dots below that mirrors the selection and is also tappable.
    private var datePlate: some View {
        GeometryReader { geometry in
            let plateHeight = max(0, geometry.size.height - 24)
            VStack(alignment: .center, spacing: 4) {
                WheelPicker(selectedDate: $selectedDate, config: Config(),
                            style: .plate, plateHeight: plateHeight)
                    .frame(height: plateHeight)
                WheelPicker(selectedDate: $selectedDate, config: Config(), style: .dots)
                    .frame(height: 20)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    var body: some View {
        let filteredEvents = EventListView.filteredEvents(events: calendarManager.events)
        HStack(alignment: .center, spacing: 14) {
            datePlate
                .frame(width: 92, alignment: .leading)

            Group {
                if filteredEvents.isEmpty {
                    EmptyEventsView(selectedDate: selectedDate)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    EventListView(events: calendarManager.events)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .listRowBackground(Color.clear)
        .frame(maxHeight: .infinity)
        .onChange(of: selectedDate) {
            Task {
                await calendarManager.updateCurrentDate(selectedDate)
            }
        }
        .onChange(of: vm.notchState) { _, _ in
            Task {
                await calendarManager.updateCurrentDate(Date.now)
                selectedDate = Date.now
            }
        }
        .onAppear {
            Task {
                await calendarManager.updateCurrentDate(Date.now)
                selectedDate = Date.now
            }
        }
    }
}

struct EmptyEventsView: View {
    let selectedDate: Date
    
    var body: some View {
        VStack {
            Image(systemName: "calendar.badge.checkmark")
                .font(.title)
                .foregroundColor(Color(white: 0.65))
            Text(Calendar.current.isDateInToday(selectedDate) ? "No events today" : "No events")
                .font(.subheadline)
                .foregroundColor(.white)
            Text("Enjoy your free time!")
                .font(.caption)
                .foregroundColor(Color(white: 0.65))
        }
    }
}

struct EventListView: View {
    @Environment(\.openURL) private var openURL
    @ObservedObject private var calendarManager = CalendarManager.shared
    let events: [EventModel]
    @Default(.autoScrollToNextEvent) private var autoScrollToNextEvent
    @Default(.showFullEventTitles) private var showFullEventTitles
    @Default(.pomodoroTab) private var pomodoroTab
    @Default(.pomodoroCalendarIcon) private var pomodoroCalendarIcon
    @Default(.callaCopilotEnabled) private var callaCopilotEnabled
    @Default(.callaQuizEnabled) private var callaQuizEnabled
    @ObservedObject private var callaEngine = CallaEngineClient.shared


    static func filteredEvents(events: [EventModel]) -> [EventModel] {
        events.filter { event in
            if event.type.isReminder {
                if case .reminder(let completed) = event.type {
                    return !completed || !Defaults[.hideCompletedReminders]
                }
            }
            // Filter out all-day events if setting is enabled
            if event.isAllDay && Defaults[.hideAllDayEvents] {
                return false
            }
            return true
        }
    }

    private var filteredEvents: [EventModel] {
        Self.filteredEvents(events: events)
    }

    private func scrollToRelevantEvent(proxy: ScrollViewProxy) {
        let now = Date()
        // Determine a single target using preferred search order:
        // 1) first non-all-day upcoming/in-progress event
        // 2) first all-day event
        // 3) last event (fallback)
        let nonAllDayUpcoming = filteredEvents.first(where: { !$0.isAllDay && $0.end > now })
        let firstAllDay = filteredEvents.first(where: { $0.isAllDay })
        let lastEvent = filteredEvents.last
        guard let target = nonAllDayUpcoming ?? firstAllDay ?? lastEvent else { return }

        Task { @MainActor in
            withTransaction(Transaction(animation: nil)) {
                proxy.scrollTo(target.id, anchor: .top)
            }
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(filteredEvents) { event in
                        // A tap gesture rather than a Button wrapper: the row now
                        // holds its own timer Button, and nested buttons do not
                        // hit-test reliably on macOS.
                        eventRow(event)
                            .contentShape(Rectangle())
                            .onTapGesture { openEvent(event) }
                            .contextMenu { rowActions(event) }
                            .id(event.id)
                    }
                }
            }
            .scrollIndicators(.never)
            .scrollContentBackground(.hidden)
            .background(Color.clear)

            .onAppear {
                scrollToRelevantEvent(proxy: proxy)
                callaEngine.refresh()
            }
            .onChange(of: filteredEvents) { _, _ in
                scrollToRelevantEvent(proxy: proxy)
            }
        }
    }

    /// Events with a video call open the call directly; everything else falls
    /// back to opening the event in the calendar app.
    private func openEvent(_ event: EventModel) {
        guard let url = event.videoCallURL ?? event.calendarAppURL() else { return }
        // Prefer the native meeting app (Zoom/Teams) when the setting is on.
        // Sandbox can't check installation up front, so attempt the app URL and
        // fall back to the browser if no handler accepts it.
        if Defaults[.openMeetingsInApp],
           let native = MeetingLinkResolver.nativeURL(for: url),
           NSWorkspace.shared.open(native) {
            // opened in the native app
        } else {
            openURL(url)
        }

    }

    /// Join opens the meeting and nothing else.
    ///
    /// It used to start Call capture for whichever event was clicked. The live
    /// call is the Wave interview now — that was the one path left that could
    /// start it as some other meeting, which would have run the interview
    /// persona and the interview's knowledge against an unrelated call.
    private func joinEvent(_ event: EventModel) {
        openEvent(event)
    }

    /// Turns the event's remaining time window into a Pomodoro plan and starts
    /// it, then jumps the notch to the timer.
    private func startPomodoro(for event: EventModel) {
        let preset = PomodoroManager.shared.selectedPreset
        let blocks = PomodoroPlanner.plan(for: event, preset: preset)
        guard !blocks.isEmpty else { return }
        PomodoroManager.shared.start(
            blocks: blocks,
            preset: preset,
            title: event.title,
            sourceEventID: event.id
        )
        CallaViewCoordinator.shared.currentView = .pomodoro
    }

    private func canStartPomodoro(for event: EventModel) -> Bool {
        pomodoroTab && pomodoroCalendarIcon && !event.isAllDay && event.eventStatus != .ended
    }

    /// The actions that used to be glyphs on the row.
    ///
    /// Moved into a right-click rather than deleted: each is still the fastest way
    /// to do its thing from here, and none of them was worth the width. A menu that
    /// comes out empty for an event none of them apply to is fine — macOS shows
    /// nothing rather than an empty box.
    @ViewBuilder
    private func rowActions(_ event: EventModel) -> some View {
        if canPrepCopilot(for: event) {
            Button(hasPrep(for: event) ? "Edit context…" : "Add context…") {
                // Same surface a drop onto the notch lands on, already pointed at
                // this meeting. Two ways in, one place to learn.
                CallaKnowledgeAttach.shared.begin(for: event)
                CallaViewCoordinator.shared.currentView = .knowledgeDrop
                NotificationCenter.default.post(name: .callaKnowledgeWantsNotch, object: nil)
            }
        }
        if callaQuizEnabled && callaCopilotEnabled && !event.isAllDay {
            Button("Start Quiz…") {
                callaEngine.prepareQuiz(for: CallaMeeting(event))
                CallaViewCoordinator.shared.currentView = .copilot
                NotificationCenter.default.post(name: .callaQuizWantsNotch, object: nil)
            }
        }
        if canStartPomodoro(for: event) {
            Button("Start a focus timer") { startPomodoro(for: event) }
        }
    }

    private func canPrepCopilot(for event: EventModel) -> Bool {
        callaCopilotEnabled && !event.isAllDay
    }

    /// Whether anything has been written for this meeting yet, so the menu can say
    /// "edit" rather than "prep". Read from the app's own cache rather than asked
    /// over XPC per row — the calendar list redraws constantly.
    private func hasPrep(for event: EventModel) -> Bool {
        CallaKnowledgeFocus.shared.hasNotes(eventID: event.id, seriesID: event.seriesID)
    }

    // A flat card: brighter for the event happening now, so the one that
    // matters is found before a title is read. The calendar's colour is the bar.
    private func cardBackground(current: Bool) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.white.opacity(current ? 0.09 : 0.045))
    }

    /// The 4pt calendar bar, flush with the card's leading edge.
    private func calendarBar(_ color: Color) -> some View {
        Rectangle()
            .fill(color)
            .frame(width: 4)
    }

    private func eventRow(_ event: EventModel) -> some View {
        let barColor = Color(event.calendar.color)
        if event.type.isReminder {
            let isCompleted: Bool
            if case .reminder(let completed) = event.type {
                isCompleted = completed
            } else {
                isCompleted = false
            }
            let isPastToday = event.start < Date.now && Calendar.current.isDateInToday(event.start)
            return AnyView(
                HStack(spacing: 9) {
                    calendarBar(barColor)
                    ReminderToggle(
                        isOn: Binding(
                            get: { isCompleted },
                            set: { newValue in
                                Task {
                                    await calendarManager.setReminderCompleted(
                                        reminderID: event.id, completed: newValue
                                    )
                                }
                            }
                        ),
                        color: barColor
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(NotchInk.primary.opacity(0.8))
                            .lineLimit(showFullEventTitles ? nil : 1)
                        Group {
                            if event.isAllDay {
                                Text("all-day")
                                    .foregroundColor(barColor)
                            } else {
                                Text(event.start, style: .time)
                                    .foregroundColor(NotchInk.tertiary)
                            }
                        }
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.trailing, 7)
                .frame(minHeight: 44)
                .background(cardBackground(current: false))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .opacity(isCompleted ? 0.4 : (isPastToday ? 0.6 : 1.0))
            )
        } else {
            let isInProgress = event.eventStatus == .inProgress
            let isEnded = event.eventStatus == .ended && Calendar.current.isDateInToday(event.start)
            // Computed once per row: the accessor runs NSDataDetector over the
            // event's notes, which is far too expensive to repeat per body pass.
            let videoCallURL = event.videoCallURL
            return AnyView(
                HStack(spacing: 9) {
                    calendarBar(barColor)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(isInProgress ? NotchInk.primary : NotchInk.primary.opacity(0.8))
                            .lineLimit(showFullEventTitles ? nil : 1)

                        HStack(spacing: 4) {
                            Group {
                                if event.isAllDay {
                                    Text("all-day")
                                        .fontWeight(.semibold)
                                        .foregroundColor(barColor)
                                } else {
                                    (Text(event.start, style: .time)
                                        + Text(" – ")
                                        + Text(event.end, style: .time))
                                        .foregroundColor(NotchInk.tertiary)
                                }
                            }
                            .monospacedDigit()

                            if let location = event.location, !location.isEmpty {
                                Text("·").foregroundColor(NotchInk.tertiary)
                                Text(location)
                                    .foregroundColor(NotchInk.tertiary)
                                    .lineLimit(1)
                            }
                        }
                        .font(.system(size: 11))
                        .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    // The row's one control, and only on the event happening
                    // now: Join on every row read as a toolbar, and the row-wide
                    // tap still opens the call for any other event. Focus timers,
                    // context and Quiz are a right-click away.
                    //
                    // A real Button rather than a glyph: it is the primary action
                    // of the row, and the row-wide tap gesture is easy to trigger
                    // by accident while scrolling.
                    if videoCallURL != nil && isInProgress {
                        Button {
                            joinEvent(event)
                        } label: {
                            Image(systemName: "video.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(NotchAccent.onAccent)
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(NotchAccent.home))
                                .contentShape(Circle())
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help("Join \(event.title)")
                        .accessibilityLabel("Join \(event.title)")
                    }
                }
                .padding(.trailing, 7)
                .frame(minHeight: 44)
                .background(cardBackground(current: isInProgress))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .opacity(isEnded ? 0.5 : 1.0)
            )
        }
    }
}

struct ReminderToggle: View {
    @Binding var isOn: Bool
    var color: Color

    var body: some View {
        Button(action: {
            isOn.toggle()
        }) {
            ZStack {
                // Outer ring
                Circle()
                    .strokeBorder(color, lineWidth: 2)
                    .frame(width: 14, height: 14)
                // Inner fill
                if isOn {
                    Circle()
                        .fill(color)
                        .frame(width: 8, height: 8)
                }
                Circle()
                    .fill(Color.black.opacity(0.001))
                    .frame(width: 14, height: 14)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .padding(0)
        .accessibilityLabel(isOn ? "Mark as incomplete" : "Mark as complete")
    }
}

#Preview {
    CalendarView()
        .frame(width: 267, height: 130)
        .background(.black)
        .environmentObject(CallaViewModel())
}

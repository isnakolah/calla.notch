import SwiftUI

// MARK: - Page shell

/// Whether a pane is being drawn inside another page.
///
/// Calendars & Lists, LocalSend, Displays and the rest used to be pages of
/// their own. They are groups now, and the page that owns them draws them in
/// place. Rather than splitting every one of those panes in two, a pane under
/// this flag drops its own title and scroll view and contributes only its
/// groups.
private struct SettingsEmbeddedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var settingsEmbedded: Bool {
        get { self[SettingsEmbeddedKey.self] }
        set { self[SettingsEmbeddedKey.self] = newValue }
    }
}

/// Every page: a title, the sentence that says what it is for, an optional
/// master switch on the right, and one scroll of groups under it.
struct SettingsPane<Content: View>: View {
    let title: String
    var detail: String?
    /// The feature's master switch, drawn in the header. With it off the page
    /// stays readable and dims, so the reader can see what they would get.
    var isOn: Binding<Bool>?
    /// Set for a record pushed over its page — the header gains a way back.
    var backTitle: String?
    @ViewBuilder var content: Content

    @Environment(\.settingsRouter) private var router
    @Environment(\.settingsEmbedded) private var embedded

    init(eyebrow: String = "", title: String, detail: String? = nil, isOn: Binding<Bool>? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.isOn = isOn
        self.content = content()
    }

    /// A sidebar page.
    init(_ section: SettingsSection, isOn: Binding<Bool>? = nil, @ViewBuilder content: () -> Content) {
        self.title = String(localized: section.title)
        self.detail = section.detail.map { String(localized: $0) }
        self.isOn = isOn
        self.content = content()
    }

    /// A named group, or a record. Groups are normally drawn embedded, where
    /// the title is the owning page's business; a record gets a back button.
    init(page: SettingsPage, titleOverride: String? = nil, isOn: Binding<Bool>? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = titleOverride ?? String(localized: page.title)
        self.detail = nil
        self.isOn = isOn
        if case .copilotKnowledgeDetail = page {
            self.backTitle = String(localized: page.section.title)
        }
        self.content = content()
    }

    var body: some View {
        if embedded {
            VStack(alignment: .leading, spacing: NotchSpace.stack) { content }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                            .padding(.horizontal, SettingsMetrics.margin)
                            .padding(.top, 30)
                            .padding(.bottom, 18)
                        VStack(alignment: .leading, spacing: SettingsMetrics.groupGap) {
                            content
                        }
                        .opacity(isOn?.wrappedValue == false ? 0.45 : 1)
                        .animation(NotchMotion.settle, value: isOn?.wrappedValue)
                        .padding(.horizontal, SettingsMetrics.margin)
                        .padding(.bottom, 28)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollContentBackground(.hidden)
                .onAppear { reveal(router?.route.focus, with: proxy) }
                .onChange(of: router?.route.focus) { _, focus in reveal(focus, with: proxy) }
            }
            .background(NotchSurface.base)
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: NotchSpace.stack) {
            VStack(alignment: .leading, spacing: 4) {
                if let backTitle, let router {
                    Button { router.pop() } label: {
                        Label(backTitle, systemImage: "chevron.backward")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut("[", modifiers: .command)
                    .padding(.bottom, 2)
                }
                Text(title)
                    .font(NotchType.paneTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail {
                    Text(detail)
                        .font(NotchType.paneDetail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let isOn {
                Toggle("", isOn: isOn.animation(NotchMotion.settle))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.large)
                    .accessibilityLabel(Text("\(title) on"))
            }
        }
    }

    /// Scrolls to the group search or a deep link asked for. The group lights
    /// itself up (see `settingsAnchor`); the focus is cleared once the light has
    /// had time to be seen, so coming back to the page does not replay it.
    private func reveal(_ focus: String?, with proxy: ScrollViewProxy) {
        guard let focus, !focus.hasPrefix("call:") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(NotchMotion.drill) { proxy.scrollTo(focus, anchor: .top) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            if router?.route.focus == focus { router?.consumeFocus() }
        }
    }
}

enum SettingsMetrics {
    /// The page margin.
    static let margin: CGFloat = 36
    /// Group to group.
    static let groupGap: CGFloat = 18
    /// A row's minimum height inside a card.
    static let rowHeight: CGFloat = 44
}

/// Marks a group as somewhere search and deep links can land.
private struct SettingsAnchorModifier: ViewModifier {
    let id: String
    @Environment(\.settingsRouter) private var router

    private var lit: Bool { router?.route.focus == id }

    func body(content: Content) -> some View {
        content
            .id(id)
            .overlay {
                RoundedRectangle(cornerRadius: NotchRadius.card + 4, style: .continuous)
                    .strokeBorder(NotchTint.active, lineWidth: 2)
                    .padding(-4)
                    .opacity(lit ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .animation(.easeInOut(duration: 0.35), value: lit)
    }
}

extension View {
    func settingsAnchor(_ id: String) -> some View {
        modifier(SettingsAnchorModifier(id: id))
    }

    func settingsAnchor(_ page: SettingsPage) -> some View {
        modifier(SettingsAnchorModifier(id: page.anchor ?? page.identifier))
    }
}

/// A pane that used to be a page, drawn as a group on the page that owns it.
struct SettingsEmbedded<Content: View>: View {
    let page: SettingsPage
    var caption: String?
    @ViewBuilder var content: Content

    init(_ page: SettingsPage, caption: String? = nil, @ViewBuilder content: () -> Content) {
        self.page = page
        self.caption = caption
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(caption ?? String(localized: page.title))
                .font(.system(size: 15, weight: .semibold))
                .padding(.top, 6)
            content
                .environment(\.settingsEmbedded, true)
        }
        .settingsAnchor(page)
    }
}

// MARK: - Card

/// A group: a short caption above, and a card holding its rows.
///
/// The caption sits outside the card rather than as its first line, so a
/// column of cards reads as a list of named groups.
struct SettingCard<Content: View>: View {
    var title: String?
    var detail: String?
    /// Set only when the card reports live state worth colouring.
    var tint: Color?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, detail: String? = nil, tint: Color? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if title != nil || detail != nil {
                SettingsCaption(title: title, detail: detail)
            }
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .settingsCardSurface(tint: tint)
        }
    }
}

/// The caption over a group.
struct SettingsCaption: View {
    var title: String?
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            if let detail {
                Text(detail)
                    .font(NotchType.rowDetail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 4)
    }
}

extension View {
    /// The card: a faint raised fill, a hairline, and — only when it is
    /// reporting something — a tint in both.
    func settingsCardSurface(tint: Color? = nil, radius: CGFloat = NotchRadius.card) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(tint.map { $0.opacity(0.08) } ?? NotchSurface.raised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(tint.map { $0.opacity(0.35) } ?? NotchSurface.hairline, lineWidth: 1)
        )
    }
}

// MARK: - Row

/// One setting, with the sentence that explains it.
struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: Control

    init(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(NotchType.rowTitle)
                if let detail {
                    Text(detail)
                        .font(NotchType.rowDetail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A fact the reader cannot change, with its value aligned right.
struct SettingFact: View {
    let title: String
    let value: String
    var tint: Color?

    var body: some View {
        HStack(spacing: 8) {
            if let tint {
                Circle().fill(tint).frame(width: 6, height: 6)
            }
            Text(title).font(NotchType.rowTitle)
            Spacer(minLength: 8)
            Text(value)
                .font(NotchType.figure)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// MARK: - Badge

struct SettingBadge: View {
    let text: String
    var tint: Color?

    init(_ text: String, tint: Color? = nil) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tint ?? .secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background((tint ?? Color.secondary).opacity(0.16),
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

// MARK: - Status

/// Granted or not, connected or not — the same mark for the same meaning.
struct SettingStatusIcon: View {
    let ok: Bool
    var size: CGFloat = 13
    var failedTint: Color = NotchTint.attention

    var body: some View {
        Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .font(.system(size: size))
            .foregroundStyle(ok ? NotchTint.healthy : failedTint)
    }
}

/// The tinted square a card or row leads with.
struct SettingGlyph: View {
    let symbol: String
    var tint: Color = NotchTint.active
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: NotchRadius.chip, style: .continuous))
    }
}

/// How far through a set of things, in things.
struct SettingProgressBar: View {
    let done: Int
    let total: Int
    var active = false

    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { geometry in
                let fraction = total == 0 ? 0 : Double(done) / Double(total)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(active ? NotchTint.active : Color.secondary)
                        .frame(width: max(0, geometry.size.width * fraction))
                }
            }
            .frame(height: 4)
            Text(label)
                .font(NotchType.figure)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    private var label: String {
        guard done != total || total == 0 else { return "Done" }
        return "\(done) of \(total)"
    }
}

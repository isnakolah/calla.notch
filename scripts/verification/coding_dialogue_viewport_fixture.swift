struct Preview: View {
    let compact: Bool
    let answer: Bool
    @State var offsets: [String: Double] = [:]
    var stress = false
    var code: String { codeBase + (stress ? "\n" + String(repeating: "# A long context line that must wrap without losing its line number or clipping the complete suggestion at the edge of the reading area.\n", count: 25) : "") }
    let codeBase = """
    def normalize_labels(values: list[str]) -> list[str]:
        # Keep input order and skip empty labels.
        seen: set[str] = set()
        labels: list[str] = []

        for value in values:
            label = value.strip()
            if label and label not in seen:
                seen.add(label)
                labels.append(label)

        return labels
    """
    var guidance: NSAttributedString {
        let text = "Why: A set recognizes previously visited values.\nLimitation: Uses extra memory.\nPending: Empty input; duplicate behavior.\nSay next: Let's cover duplicates."
        let prose = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white])
        if answer { return prose }
        let result = NSMutableAttributedString(attributedString: CodingCodeFormatter.format(code))
        result.append(NSAttributedString(string: "\n")); result.append(prose)
        return result
    }
    var body: some View {
        VStack(spacing: compact ? 4 : 8) {
            if !compact { HStack {
                Image(systemName: "chevron.left.forwardslash.chevron.right").foregroundStyle(.mint)
                Text("LIVE CODE").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1.4)
                Spacer()
                Circle().fill(.mint).frame(width: 5, height: 5)
                Text("Listening").font(.system(size: 11))
                Text("96:24").font(.system(size: 11, design: .monospaced))
                Button {} label: { Label("Hold", systemImage: "pause.fill") }.buttonStyle(CodingControlStyle())
                Button {} label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }.buttonStyle(CodingControlStyle())
            }
            }
            CodingReadingPane(document: .init(identity: "sample", title: answer ? "Explain the simple approach before implementing" : "Normalize labels while preserving their original order.", eyebrow: answer ? "REASONING" : "STEP 03", content: guidance, code: answer ? nil : code, placement: "normalize_labels · line 24"), compact: compact, offsets: $offsets, expand: {}, copy: {}, copyShortcut: "⌥⌘K", previousShortcut: "⇧⌥⌘←", nextShortcut: "⇧⌥⌘→")
            Text("Say next: Let's cover duplicates.").font(.system(size: compact ? 10 : 11, weight: .medium))
                .foregroundStyle(.mint).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            if !compact {
                HStack {
                    Text("Window ⇧⌥⌘W").font(.system(size: 9))
                    Text("src/normalization.py · normalize_labels").lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.72))
            }
            HStack(spacing: 6) {
                if compact { key("Window", "⇧⌥⌘W"); Text("normalization.py").font(.system(size: 9)).lineLimit(1).truncationMode(.middle) }
                key("History", "⌥⌘S")
                key("Ask", "⌥⌘Q")
                if compact { key("Hold", "⇧⌥⌘␣") }
                Spacer(minLength: 0)
                key("Run", "⌥⌘R")
                key(answer ? "Return" : "Next", "⇧⌥⌘↩")
                if compact { key("Expand", "⌥⌘T") }
                key("End", "⌥⌘C")
            }.frame(height: compact ? 22 : 30)

        }.padding(.horizontal, compact ? 12 : 24).padding(.top, compact ? 0 : 4).padding(.bottom, compact ? 4 : 18)
          .foregroundStyle(.white).background(Color(red: 0.065, green: 0.07, blue: 0.075))
    }
    func key(_ title: String, _ shortcut: String) -> some View {
        Button {} label: {
            VStack(spacing: 0) {
                Text(title).font(.system(size: compact ? 9 : 10, weight: .medium))
                Text(shortcut).font(.system(size: compact ? 8 : 9, design: .monospaced)).foregroundStyle(.white.opacity(0.72))
            }.fixedSize()
        }.buttonStyle(.borderless)
    }

}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
for (name, width, height, compact, answer) in [
    ("expanded", 600, 340, false, false), ("compact", 600, 200, true, false), ("compact-saved", 600, 161, true, false), ("compact-min", 460, 150, true, false),
    ("minimum", 460, 240, false, false), ("maximum", 900, 560, false, false),
    ("answer", 600, 340, false, true), ("compact-answer", 460, 150, true, true), ("code-default", 600, 340, false, false), ("long-code", 460, 240, false, false)] {
    let view = NSHostingView(rootView: Preview(compact: compact, answer: answer, stress: name == "long-code").frame(width: CGFloat(width), height: CGFloat(height - 52)))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height - 52), styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1] + "/\(name).png"))
}
print("Rendered live coding component fixtures")

// The same native reader must retain an exact position through interruptions.
final class ReadingProbe: ObservableObject {
    @Published var identity = "code"
    @Published var offsets: [String: Double] = [:]
}
struct ReadingProbeView: View {
    @ObservedObject var probe: ReadingProbe
    var body: some View {
        WaveReadingScroll(content: NSAttributedString(string: String(repeating: "A complete readable line\n", count: 80), attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)]), identity: probe.identity, offsets: $probe.offsets)
    }
}
func descendantScroll(_ view: NSView) -> NSScrollView? {
    if let scroll = view as? NSScrollView { return scroll }
    return view.subviews.compactMap(descendantScroll).first
}
let probe = ReadingProbe()
let host = NSHostingView(rootView: ReadingProbeView(probe: probe))
let probeWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 160), styleMask: .borderless, backing: .buffered, defer: false)
probeWindow.contentView = host
host.layoutSubtreeIfNeeded()
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
let reader = descendantScroll(host)!
reader.contentView.scroll(to: NSPoint(x: 0, y: 103))
reader.reflectScrolledClipView(reader.contentView)
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
assert(abs((probe.offsets["code"] ?? -1) - 103) < 1)
probe.identity = "answer"
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
assert(reader.contentView.bounds.origin.y == 0)
reader.contentView.scroll(to: NSPoint(x: 0, y: 61))
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
probe.identity = "code"
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
assert(abs(reader.contentView.bounds.origin.y - 103) < 1)
probe.identity = "answer"
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
assert(abs(reader.contentView.bounds.origin.y - 61) < 1)
let source = "def label(value):\n\treturn '✓' + value\n"
let formatted = CodingCodeFormatter.format(source).string.components(separatedBy: .newlines)
assert(formatted.map { String($0.dropFirst(5)) }.joined(separator: "\n") == source)
print("PASS: exact independent scroll restoration; code characters preserved with display-only line numbers")

probeWindow.setContentSize(NSSize(width: 400, height: 50))
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
let beforeScroll = reader.contentView.bounds.origin.y
NotificationCenter.default.post(name: .callaCodingScroll, object: 8)
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
let distance = reader.contentView.bounds.origin.y - beforeScroll
assert(distance > 0 && distance < reader.contentSize.height)
print("PASS: keyboard scrolling overlaps the previous viewport at compact height")

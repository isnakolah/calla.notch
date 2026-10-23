import Foundation

/// Makes untrusted calendar invite fields fit the engine's meeting contract.
/// Keep these limits aligned with CallaCopilotCommandValidation.
public enum CalendarMeetingInput {
    public static let titleLimit = 200
    public static let notesLimit = 4_000
    public static let attendeeLimit = 120
    public static let attendeeCount = 40
    public static let identifierLimit = 256

    public static func text(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let safeScalars = value.unicodeScalars.filter { scalar in
            scalar.properties.generalCategory != .control || scalar == "\n" || scalar == "\r" || scalar == "\t"
        }
        let cleaned = String(String.UnicodeScalarView(safeScalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: "\n")
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(limit))
    }

    public static func identifier(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, value.count <= identifierLimit,
              !value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else { return nil }
        return value
    }

    public static func attendees(_ names: [String]) -> [String] {
        names.prefix(attendeeCount).compactMap { text($0, limit: attendeeLimit) }
    }
}

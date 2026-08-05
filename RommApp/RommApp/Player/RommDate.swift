import Foundation

/// Parsing for RomM's own timestamp strings, used wherever a save or state's
/// `updated_at` needs to become a real `Date` rather than just sorted as
/// text.
enum RommDate {
    /// Tries both ISO 8601 shapes RomM's backend (a Python/FastAPI stack,
    /// whose ORM commonly emits `datetime.isoformat()`) could plausibly be
    /// sending, since neither the OpenAPI schema (`"type": "string"`, no
    /// format) nor a live authenticated sample was available to confirm
    /// which. Returns nil rather than guess when neither matches, which
    /// callers should treat as a genuine unknown, not as license to assume
    /// either side of a comparison wins.
    static func parse(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        return whole.date(from: raw)
    }

    /// For a save or state row: "2 hours ago" reads better than a filename
    /// nobody chose, since RomM auto-names every upload and this app's own
    /// manual save has historically sent an identical name for every state
    /// of every game. Falls back to the raw string only when parsing
    /// genuinely fails, so a row is never left blank.
    static func relativeLabel(_ raw: String?) -> String {
        guard let date = parse(raw) else { return raw ?? "Unknown time" }
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }
}

import Foundation

/// One line of a release's "What's new" summary: an SF Symbol name, a heading and a subheading, all plain text.
public struct WhatsNewItem: Equatable, Sendable {
    public var icon: String
    public var heading: String
    public var subheading: String
}

/// The release summary the update window shows. The release writes it as 3 to 5 lines of `icon | heading | subheading`
/// (`docs/whats-new/<version>.txt`) and it travels in the appcast item; `scripts/whats-new.sh check` applies the same
/// rules at release time, so keep the two in step.
public enum WhatsNew {
    public static let itemRange = 3...5

    /// The items, or nil when the text is missing or any line is malformed: the window then falls back to the plain prompt.
    public static func parse(_ text: String?) -> [WhatsNewItem]? {
        guard let text else { return nil }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard itemRange.contains(lines.count) else { return nil }
        var items: [WhatsNewItem] = []
        for line in lines {
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == 3, !fields[1].isEmpty, !fields[2].isEmpty,
                  !fields[0].isEmpty, fields[0].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ".") })
            else { return nil }
            items.append(WhatsNewItem(icon: fields[0], heading: fields[1], subheading: fields[2]))
        }
        return items
    }
}

import Foundation

/// The release summary shown in the update window: three to five lines of "icon | heading | subheading", carried in
/// the signed update feed as the item's whatsNew element. scripts/whats-new.sh checks the same rules at release time,
/// so a release the script accepts is one this parser shows; keep the two identical.
public enum WhatsNew {
    public struct Item: Equatable, Sendable {
        /// An SF Symbol name: letters, digits and dots.
        public let icon: String
        public let heading: String
        public let subheading: String
    }

    /// The items, or nil when the summary is missing or any line is malformed, so the plain prompt shows instead.
    public static func parse(_ text: String?) -> [Item]? {
        let blanks = CharacterSet(charactersIn: " \t\r")
        // Split on the newline string: Swift reads CRLF as one Character, which a Character split would miss.
        let lines = (text ?? "").components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: blanks) }
            .filter { !$0.isEmpty }
        guard (3...5).contains(lines.count) else { return nil }
        var items: [Item] = []
        for line in lines {
            let fields = line.components(separatedBy: "|").map { $0.trimmingCharacters(in: blanks) }
            guard fields.count == 3, !fields[1].isEmpty, !fields[2].isEmpty, isSymbolName(fields[0]) else { return nil }
            items.append(Item(icon: fields[0], heading: fields[1], subheading: fields[2]))
        }
        return items
    }

    private static func isSymbolName(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy { ($0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0))) || $0 == "." }
    }
}

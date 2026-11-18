import SwiftUI
import EnsembleCore

/// The body of the update window: the release's three to five items, each an icon, a heading and a subheading, in
/// plain text. A later optional image or animation for a major release goes above the list in this same column.
struct WhatsNewView: View {
    let items: [WhatsNew.Item]
    /// Opens the release page in the browser; nil when the feed names none.
    let notesLink: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 12) {
                    // A name macOS does not know draws nothing; the text still carries the item.
                    Image(systemName: item.icon)
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 30)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.heading).font(.headline)
                        Text(item.subheading).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
            }
            if let notesLink {
                Button("Full release notes", action: notesLink).buttonStyle(.link)
            }
        }
        .frame(width: 340, alignment: .leading)
        .padding(.vertical, 4)
    }
}

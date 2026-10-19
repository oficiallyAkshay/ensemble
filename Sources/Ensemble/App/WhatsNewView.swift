import SwiftUI
import EnsembleCore

/// The body of the update window: a release's three to five items, each one icon, one heading and one subheading.
/// Text only. A later image, illustration or animation for a major release goes in the empty slot above the list.
struct WhatsNewView: View {
    let items: [WhatsNewItem]
    /// Opens the full release page in the browser; nil when the feed names none.
    let notesLink: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: item.icon)
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.heading).font(.headline)
                        Text(item.subheading).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let notesLink {
                Button("Full release notes", action: notesLink).buttonStyle(.link)
            }
        }
        .frame(width: 340, alignment: .leading)
        .padding(.vertical, 4)
    }
}

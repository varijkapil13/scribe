import SwiftUI

/// Settings > Storage & Sync: what iCloud task sync covers on this Mac —
/// tasks, projects, areas and headings — plus anything still waiting for a
/// related item to arrive from another device.
struct TaskSyncCountsRow: View {
    @State private var counts: TaxonomySyncCounts?

    var body: some View {
        Group {
            if let counts {
                LabeledContent("Syncing") {
                    Text(counts.summaryText)
                        .foregroundStyle(.secondary)
                }
                if let waiting = counts.waitingText {
                    Label(waiting, systemImage: "clock.arrow.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task { counts = try? TaskStore.shared.taxonomySyncCounts() }
    }
}

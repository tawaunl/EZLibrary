import SwiftUI

struct PendingIntentsView: View {
    @Environment(SnapshotStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !store.pendingIntents.isEmpty {
                    Section {
                        Text("These changes will be applied to your Serato library the next time EZLibrary syncs from your Mac. Swipe left on any item to remove it.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach(store.pendingIntents) { intent in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(intent.operation.summary)
                            .font(.body)
                        Text(intent.createdAt.formatted(.relative(presentation: .named)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        store.removeIntent(id: store.pendingIntents[index].id)
                    }
                }
            }
            .navigationTitle("Pending Changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if store.hasPendingIntents {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Clear All", role: .destructive) {
                            store.clearAllIntents()
                            dismiss()
                        }
                        .foregroundStyle(.red)
                    }
                }
            }
            .overlay {
                if store.pendingIntents.isEmpty {
                    ContentUnavailableView(
                        "No Pending Changes",
                        systemImage: "checkmark.circle",
                        description: Text("Edit tracks or crates and your changes will appear here before syncing to your Mac.")
                    )
                }
            }
        }
    }
}

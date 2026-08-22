import SwiftUI

struct PendingIntentsView: View {
    @Environment(SnapshotStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var isExporting = false
    @State private var exportError: String? = nil

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

                Section("Sync to Mac") {
                    if let error = exportError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    Button {
                        Task { await exportSnapshot() }
                    } label: {
                        HStack {
                            Label(
                                store.hasPendingIntents
                                    ? "Apply & Write Snapshot"
                                    : "Write Snapshot to Folder",
                                systemImage: "arrow.up.doc.fill"
                            )
                            Spacer()
                            if isExporting {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isExporting)

                    Text("Writes the effective library snapshot (with all pending changes applied) to your sync folder. EZLibrary on Mac will pick it up the next time it opens.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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

    private func exportSnapshot() async {
        isExporting = true
        exportError = nil
        defer { isExporting = false }
        do {
            try store.exportEffectiveSnapshot()
            dismiss()
        } catch {
            exportError = error.localizedDescription
        }
    }
}

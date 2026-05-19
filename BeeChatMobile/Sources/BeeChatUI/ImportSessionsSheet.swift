import SwiftUI
import BeeChatPersistence
import BeeChatMobileKit

struct ImportSessionsSheet: View {
    let candidates: [Session]
    @State private var selectedIds: Set<String> = []
    let onImport: ([Session]) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if candidates.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tray")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)
                        Text("No sessions available to import")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(candidates, id: \.id, selection: $selectedIds) { session in
                        VStack(alignment: .leading) {
                            Text(session.title ?? session.customName ?? "Untitled")
                                .font(.headline)
                            if let preview = session.lastMessagePreview {
                                Text(preview)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Text(session.lastMessageAt?.formatted(.relative(presentation: .named)) ?? "")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .environment(\.editMode, .constant(.active))
                }
            }
            .navigationTitle("Import Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import \(selectedIds.count)") {
                        let selected = candidates.filter { selectedIds.contains($0.id) }
                        onImport(selected)
                        dismiss()
                    }
                    .disabled(selectedIds.isEmpty)
                }
            }
        }
    }
}

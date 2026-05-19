import SwiftUI
import BeeChatMobileKit

struct NewTopicSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @FocusState private var isNameFocused: Bool

    let onCreate: (String) -> Void

    @State private var showDiscardConfirmation = false

    private var isNameValid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 80
    }

    private var isDirty: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("What would you like to talk about?")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TextField("Topic name", text: $name)
                    .focused($isNameFocused)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        if isNameValid { createAndDismiss() }
                    }

                HStack {
                    Text("\(name.count)/80")
                        .font(.caption)
                        .foregroundStyle(name.count > 80 ? .red : .secondary)
                    Spacer()
                }
            }
            .padding()
            .navigationTitle("New Topic")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if isDirty {
                            showDiscardConfirmation = true
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        createAndDismiss()
                    }
                    .disabled(!isNameValid)
                }
            }
            .alert("Discard topic draft?", isPresented: $showDiscardConfirmation) {
                Button("Keep Editing", role: .cancel) {}
                Button("Discard", role: .destructive) { dismiss() }
            } message: {
                Text("Your topic name will be lost.")
            }
        }
        .onAppear {
            isNameFocused = true
        }
        .frame(minWidth: 320, maxWidth: 360, minHeight: 220)
    }

    private func createAndDismiss() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isNameValid else { return }
        onCreate(trimmed)
        dismiss()
    }
}

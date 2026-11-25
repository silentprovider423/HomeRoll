import SwiftUI

/// Eingabe als kleiner Bogen statt Alert mit Textfeld: Im Alert kam auf manchen iPhones die Tastatur nicht hoch
/// (GitHub #65, #66). Hier bekommt das Feld beim Erscheinen sicher den Fokus.
struct TextPrompt: View {
    let title: String
    let placeholder: String
    @State var text: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                TextField(placeholder, text: $text)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit(save)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(String(localized: "Abbrechen")) { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "Sichern"), action: save).bold()
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.height(200)])
        .task { try? await Task.sleep(for: .milliseconds(350)); focused = true }
    }

    private func save() {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        onSave(t); dismiss()
    }
}

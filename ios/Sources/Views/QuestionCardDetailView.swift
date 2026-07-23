import SwiftUI

struct QuestionCardDetailView: View {
    @EnvironmentObject var inboxStore: InboxStore
    @Environment(\.dismiss) private var dismiss
    let card: QuestionCard
    @State private var note = ""
    @State private var submitting = false

    var body: some View {
        VStack(spacing: 12) {
            bodyView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let answeredValue = card.answeredValue {
                Label("Answered: \(answeredValue)", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .padding(.bottom)
            } else {
                TextField("Optional note (signed with your answer)", text: $note, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal)
                answerButtons
            }
            if let statusMessage = inboxStore.statusMessage {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .navigationTitle(card.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private var bodyView: some View {
        if card.bodyContentType == "html" {
            HtmlBodyView(htmlContent: card.bodyContent)
        } else {
            ScrollView {
                Text(card.bodyContent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
    }

    private var answerButtons: some View {
        HStack(spacing: 8) {
            ForEach(card.buttons) { button in
                Button {
                    submit(button)
                } label: {
                    Text(button.label)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.borderedProminent)
                .disabled(submitting)
            }
        }
        .padding([.horizontal, .bottom])
    }

    private func submit(_ button: QuestionButton) {
        submitting = true
        Task {
            await inboxStore.submitAnswer(card: card, button: button, note: note)
            submitting = false
            if inboxStore.statusMessage == nil { dismiss() }
        }
    }
}

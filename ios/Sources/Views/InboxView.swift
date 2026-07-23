import SwiftUI

struct InboxView: View {
    @EnvironmentObject var inboxStore: InboxStore

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Inbox")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink {
                            KeysView()
                        } label: {
                            Image(systemName: "key")
                        }
                    }
                }
        }
    }

    @ViewBuilder private var content: some View {
        switch inboxStore.enrollmentPhase {
        case .needsIdentity, .needsPeer:
            EnrollmentView()
        case .ready:
            if inboxStore.unlocked {
                cardList
            } else {
                unlockPrompt
            }
        }
    }

    private var unlockPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.circle")
                .font(.system(size: 56))
            Button("Unlock inbox with Face ID") {
                Task { await inboxStore.unlock() }
            }
            .buttonStyle(.borderedProminent)
            if let statusMessage = inboxStore.statusMessage {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .task { await inboxStore.unlock() }
    }

    private var cardList: some View {
        List {
            if pendingCards.isEmpty && answeredCards.isEmpty {
                Text("No messages yet")
                    .foregroundStyle(.secondary)
            }
            if !pendingCards.isEmpty {
                Section("Pending") {
                    ForEach(pendingCards) { card in
                        cardRow(card)
                    }
                }
            }
            if !answeredCards.isEmpty {
                Section("Answered") {
                    ForEach(answeredCards) { card in
                        cardRow(card)
                    }
                }
            }
        }
        .refreshable { await inboxStore.refresh() }
        .task {
            while !Task.isCancelled {
                await inboxStore.refresh()
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    private func cardRow(_ card: QuestionCard) -> some View {
        NavigationLink {
            QuestionCardDetailView(card: card)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(card.title)
                    .font(.headline)
                HStack {
                    Text(card.createdAt, style: .relative)
                    if let answeredValue = card.answeredValue {
                        Spacer()
                        Label(answeredValue, systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var pendingCards: [QuestionCard] {
        inboxStore.cards.filter { $0.answeredValue == nil }
    }

    private var answeredCards: [QuestionCard] {
        inboxStore.cards.filter { $0.answeredValue != nil }
    }
}

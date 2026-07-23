import Foundation

struct TranscriptSegment: Identifiable, Equatable {
    let id: UUID
    let text: String

    init(text: String) {
        id = UUID()
        self.text = text
    }
}

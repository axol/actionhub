import Foundation

@MainActor
final class TranscriptBuffer: ObservableObject {
    @Published private(set) var segments: [TranscriptSegment] = []
    @Published var livePartial = ""

    var onSegmentCountChange: ((Int) -> Void)?

    var assembledText: String {
        segments.map(\.text).joined(separator: " ")
    }

    var isEmpty: Bool {
        segments.isEmpty && livePartial.isEmpty
    }

    func appendCommitted(_ text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        segments.append(TranscriptSegment(text: trimmedText))
        onSegmentCountChange?(segments.count)
    }

    func drop(_ segmentId: UUID) {
        segments.removeAll { $0.id == segmentId }
        onSegmentCountChange?(segments.count)
    }

    func clear() {
        segments.removeAll()
        livePartial = ""
        onSegmentCountChange?(0)
    }
}

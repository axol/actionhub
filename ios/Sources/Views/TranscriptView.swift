import SwiftUI

struct TranscriptView: View {
    @ObservedObject var transcriptBuffer: TranscriptBuffer

    var body: some View {
        if !transcriptBuffer.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(transcriptBuffer.segments) { segment in
                        HStack(alignment: .top) {
                            Text(segment.text)
                                .font(.callout)
                            Spacer()
                            Button {
                                transcriptBuffer.drop(segment.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(8)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if !transcriptBuffer.livePartial.isEmpty {
                        Text("… \(transcriptBuffer.livePartial)")
                            .font(.callout)
                            .italic()
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                    }
                }
            }
            .frame(maxHeight: 200)
        }
    }
}

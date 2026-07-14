import SwiftUI

struct EventLogView: View {
    let eventLog: [String]

    var body: some View {
        List(Array(eventLog.reversed()), id: \.self) { eventLine in
            Text(eventLine)
                .font(.system(.footnote, design: .monospaced))
        }
        .listStyle(.plain)
    }
}

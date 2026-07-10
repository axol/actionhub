import SwiftUI

@main
struct ActionHubApp: App {
    @StateObject private var walkController = WalkController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(walkController)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var walkController: WalkController

    var body: some View {
        VStack(spacing: 12) {
            Text("actionhub")
                .font(.title2)
                .bold()
            Text(walkController.relayStatus)
                .foregroundStyle(.secondary)
            Text(walkController.scribeStatus)
                .foregroundStyle(.secondary)
            Text(walkController.activityStatus)
                .font(.headline)
            Toggle("walk audio", isOn: $walkController.walkAudioEnabled)
                .padding(.horizontal)
            List(Array(walkController.eventLog.reversed()), id: \.self) { eventLine in
                Text(eventLine)
                    .font(.system(.footnote, design: .monospaced))
            }
            .listStyle(.plain)
        }
        .padding()
        .onAppear { walkController.start() }
    }
}

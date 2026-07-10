import SwiftUI

@main
struct ActionHubApp: App {
    @StateObject private var phoneController = PhoneController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(phoneController)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var phoneController: PhoneController

    var body: some View {
        VStack(spacing: 12) {
            Text("actionhub")
                .font(.title2)
                .bold()
            Text(phoneController.relayStatus)
                .foregroundStyle(.secondary)
            Text(phoneController.scribeStatus)
                .foregroundStyle(.secondary)
            Text("audio: \(phoneController.audioOwner)")
                .foregroundStyle(.secondary)
            Text(phoneController.activityStatus)
                .font(.headline)
            HStack(spacing: 16) {
                Button {
                    phoneController.sendCommand("previousTrackCommand")
                } label: {
                    Image(systemName: "xmark")
                        .font(.title)
                        .frame(maxWidth: .infinity, minHeight: 64)
                }
                .buttonStyle(.bordered)
                Button {
                    phoneController.sendCommand("nextTrackCommand")
                } label: {
                    Image(systemName: phoneController.activityStatus == "recording" ? "paperplane.fill" : "mic.fill")
                        .font(.title)
                        .frame(maxWidth: .infinity, minHeight: 64)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
            List(Array(phoneController.eventLog.reversed()), id: \.self) { eventLine in
                Text(eventLine)
                    .font(.system(.footnote, design: .monospaced))
            }
            .listStyle(.plain)
        }
        .padding()
        .onAppear { phoneController.start() }
    }
}

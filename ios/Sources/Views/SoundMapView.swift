import SwiftUI

struct SoundMapView: View {
    @ObservedObject var presetStore: PresetStore
    @ObservedObject var soundLibrary: SoundLibrary
    let presetId: UUID

    @State private var soundPlayer = SoundPlayer()

    var body: some View {
        List {
            Section("events") {
                ForEach(SettingsSchema.soundEvents, id: \.self) { eventName in
                    HStack {
                        Button {
                            preview(eventName)
                        } label: {
                            Image(systemName: "play.circle")
                        }
                        .buttonStyle(.borderless)
                        Picker(eventName, selection: assignmentBinding(for: eventName)) {
                            Text("off").tag("off")
                            ForEach(soundLibrary.allSoundNames, id: \.self) { soundName in
                                Text(soundName).tag(soundName)
                            }
                        }
                    }
                }
            }
            Section {
                NavigationLink("generate new sound") {
                    SoundStudioView(soundLibrary: soundLibrary)
                }
            }
        }
        .navigationTitle("sound effects")
    }

    private var resolver: SettingsResolver {
        SettingsResolver(preset: presetStore.preset(withId: presetId))
    }

    private func assignmentBinding(for eventName: String) -> Binding<String> {
        Binding(
            get: { resolver.soundAssignments[eventName] ?? eventName },
            set: { presetStore.updateSoundAssignment(event: eventName, to: $0, in: presetId) }
        )
    }

    private func preview(_ eventName: String) {
        guard let soundName = resolver.soundName(for: eventName),
              let soundUrl = soundLibrary.url(for: soundName) else { return }
        soundPlayer.play(soundUrl)
    }
}

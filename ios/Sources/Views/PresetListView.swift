import SwiftUI

struct PresetListView: View {
    @ObservedObject var presetStore: PresetStore
    @ObservedObject var soundLibrary: SoundLibrary
    @State private var newPresetName = ""

    var body: some View {
        List {
            Section {
                ForEach(presetStore.presets) { preset in
                    NavigationLink {
                        PresetEditView(presetStore: presetStore, soundLibrary: soundLibrary, presetId: preset.id)
                    } label: {
                        HStack {
                            Text(preset.name)
                            Spacer()
                            if preset.id == presetStore.activePresetId {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            presetStore.deletePreset(preset.id)
                        } label: {
                            Text("delete")
                        }
                        Button {
                            presetStore.activatePreset(preset.id)
                        } label: {
                            Text("activate")
                        }
                    }
                }
            }
            Section("new preset (copies active)") {
                HStack {
                    TextField("preset name", text: $newPresetName)
                    Button("add") {
                        presetStore.addPreset(named: trimmedNewPresetName)
                        newPresetName = ""
                    }
                    .disabled(trimmedNewPresetName.isEmpty)
                }
            }
        }
        .navigationTitle("presets")
    }

    private var trimmedNewPresetName: String {
        newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

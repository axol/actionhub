import SwiftUI

struct PresetEditView: View {
    @ObservedObject var presetStore: PresetStore
    @ObservedObject var soundLibrary: SoundLibrary
    let presetId: UUID

    var body: some View {
        Form {
            Section("name") {
                TextField("name", text: nameBinding)
            }
            Section("settings") {
                ForEach(SettingsSchema.definitions, id: \.key) { definition in
                    settingRow(for: definition)
                }
            }
            Section("show on main page") {
                ForEach(SettingsSchema.definitions.filter(\.showableOnMain), id: \.key) { definition in
                    Toggle(definition.label, isOn: mainPageBinding(for: definition.key))
                }
            }
        }
        .navigationTitle(preset.name)
    }

    private var preset: Preset {
        presetStore.preset(withId: presetId)
    }

    private var resolver: SettingsResolver {
        SettingsResolver(preset: preset)
    }

    @ViewBuilder
    private func settingRow(for definition: SettingDefinition) -> some View {
        switch definition.kind {
        case .choice(let options):
            Picker(definition.label, selection: choiceBinding(for: definition)) {
                ForEach(options, id: \.self) { option in
                    Text(option)
                }
            }
        case .toggle:
            Toggle(definition.label, isOn: toggleBinding(for: definition))
        case .soundMap:
            NavigationLink(definition.label) {
                SoundMapView(presetStore: presetStore, soundLibrary: soundLibrary, presetId: presetId)
            }
        }
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { preset.name },
            set: { presetStore.renamePreset(presetId, to: $0) }
        )
    }

    private func choiceBinding(for definition: SettingDefinition) -> Binding<String> {
        Binding(
            get: {
                guard case .text(let textValue)? = resolver.values[definition.key] else { return "" }
                return textValue
            },
            set: { presetStore.updateValue(definition.key, to: .text($0), in: presetId) }
        )
    }

    private func toggleBinding(for definition: SettingDefinition) -> Binding<Bool> {
        Binding(
            get: {
                guard case .flag(let flagValue)? = resolver.values[definition.key] else { return false }
                return flagValue
            },
            set: { presetStore.updateValue(definition.key, to: .flag($0), in: presetId) }
        )
    }

    private func mainPageBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: { preset.mainPageKeys.contains(key) },
            set: { presetStore.setMainPageVisibility(key, visible: $0, in: presetId) }
        )
    }
}

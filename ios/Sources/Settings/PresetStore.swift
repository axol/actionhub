import Foundation

@MainActor
final class PresetStore: ObservableObject {
    @Published private(set) var presets: [Preset] = []
    @Published private(set) var activePresetId: UUID

    var onSettingsChange: (() -> Void)?
    var onSharedSettingsChange: (() -> Void)?

    private let presetsDirectory: URL
    private static let activePresetDefaultsKey = "activePresetId"

    init() {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        presetsDirectory = documentsDirectory.appendingPathComponent("presets")
        try? FileManager.default.createDirectory(at: presetsDirectory, withIntermediateDirectories: true)
        var loadedPresets = Self.loadPresets(from: presetsDirectory)
        if loadedPresets.isEmpty {
            loadedPresets = Self.seedPresets()
            for seededPreset in loadedPresets {
                Self.persist(seededPreset, in: presetsDirectory)
            }
        }
        presets = loadedPresets
        let storedId = UserDefaults.standard.string(forKey: Self.activePresetDefaultsKey).flatMap(UUID.init(uuidString:))
        activePresetId = loadedPresets.first { $0.id == storedId }?.id ?? loadedPresets[0].id
    }

    var activePreset: Preset {
        preset(withId: activePresetId)
    }

    var activeSettings: SettingsResolver {
        SettingsResolver(preset: activePreset)
    }

    func preset(withId presetId: UUID) -> Preset {
        presets.first { $0.id == presetId } ?? presets[0]
    }

    func activatePreset(_ presetId: UUID) {
        guard presets.contains(where: { $0.id == presetId }) else { return }
        let previousSharedValues = activeSettings.sharedWithHubValues
        activePresetId = presetId
        UserDefaults.standard.set(presetId.uuidString, forKey: Self.activePresetDefaultsKey)
        notifyChange(previousSharedValues: previousSharedValues)
    }

    func addPreset(named presetName: String) {
        var newPreset = activePreset
        newPreset.id = UUID()
        newPreset.name = presetName
        presets.append(newPreset)
        Self.persist(newPreset, in: presetsDirectory)
    }

    func deletePreset(_ presetId: UUID) {
        guard presets.count > 1 else { return }
        presets.removeAll { $0.id == presetId }
        try? FileManager.default.removeItem(at: fileUrl(for: presetId))
        if activePresetId == presetId {
            activatePreset(presets[0].id)
        }
    }

    func renamePreset(_ presetId: UUID, to newName: String) {
        mutatePreset(presetId) { preset in
            preset.name = newName
        }
    }

    func updateValue(_ key: String, to newValue: SettingValue, in presetId: UUID) {
        mutatePreset(presetId) { preset in
            preset.values[key] = newValue
        }
    }

    func updateSoundAssignment(event eventName: String, to soundName: String, in presetId: UUID) {
        var assignments = SettingsResolver(preset: preset(withId: presetId)).soundAssignments
        if soundName == eventName {
            assignments.removeValue(forKey: eventName)
        } else {
            assignments[eventName] = soundName
        }
        updateValue("soundMap", to: .soundAssignments(assignments), in: presetId)
    }

    func setMainPageVisibility(_ key: String, visible: Bool, in presetId: UUID) {
        mutatePreset(presetId) { preset in
            preset.mainPageKeys.removeAll { $0 == key }
            if visible {
                preset.mainPageKeys.append(key)
            }
        }
    }

    func cycleValue(_ key: String) {
        guard let definition = SettingsSchema.definition(for: key) else { return }
        switch definition.kind {
        case .choice(let options):
            let currentValue = activeSettings.values[key]
            let currentIndex = options.firstIndex { .text($0) == currentValue } ?? 0
            let nextOption = options[(currentIndex + 1) % options.count]
            updateValue(key, to: .text(nextOption), in: activePresetId)
        case .toggle:
            guard case .flag(let flagValue)? = activeSettings.values[key] else { return }
            updateValue(key, to: .flag(!flagValue), in: activePresetId)
        case .soundMap:
            break
        }
    }

    private func mutatePreset(_ presetId: UUID, _ mutation: (inout Preset) -> Void) {
        guard let presetIndex = presets.firstIndex(where: { $0.id == presetId }) else { return }
        let previousSharedValues = activeSettings.sharedWithHubValues
        mutation(&presets[presetIndex])
        Self.persist(presets[presetIndex], in: presetsDirectory)
        if presetId == activePresetId {
            notifyChange(previousSharedValues: previousSharedValues)
        }
    }

    private func notifyChange(previousSharedValues: [String: SettingValue]) {
        onSettingsChange?()
        if previousSharedValues != activeSettings.sharedWithHubValues {
            onSharedSettingsChange?()
        }
    }

    private func fileUrl(for presetId: UUID) -> URL {
        presetsDirectory.appendingPathComponent("\(presetId.uuidString).json")
    }

    private static func persist(_ preset: Preset, in directory: URL) {
        guard let presetData = try? JSONEncoder().encode(preset) else { return }
        try? presetData.write(to: directory.appendingPathComponent("\(preset.id.uuidString).json"))
    }

    private static func loadPresets(from directory: URL) -> [Preset] {
        let fileUrls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return fileUrls
            .filter { $0.pathExtension == "json" }
            .compactMap { fileUrl in
                guard let presetData = try? Data(contentsOf: fileUrl) else { return nil }
                return try? JSONDecoder().decode(Preset.self, from: presetData)
            }
            .sorted { $0.name < $1.name }
    }

    private static func seedPresets() -> [Preset] {
        let allSoundsOff = Dictionary(uniqueKeysWithValues: SettingsSchema.soundEvents.map { ($0, "off") })
        return [
            Preset(name: "default"),
            Preset(
                name: "silent vad",
                values: [
                    "mode": .text("vad"),
                    "soundMap": .soundAssignments(allSoundsOff),
                ]
            ),
        ]
    }
}

import Foundation

struct SettingsResolver {
    let values: [String: SettingValue]

    init(preset: Preset) {
        var resolvedValues: [String: SettingValue] = [:]
        for definition in SettingsSchema.definitions {
            resolvedValues[definition.key] = preset.values[definition.key] ?? definition.defaultValue
        }
        values = resolvedValues
    }

    var mode: String { textValue("mode") }
    var sendPhraseEnabled: Bool { flagValue("sendPhraseEnabled") }
    var showDiscardButton: Bool { flagValue("showDiscardButton") }
    var showSendButton: Bool { flagValue("showSendButton") }
    var showMuteButton: Bool { flagValue("showMuteButton") }

    var soundAssignments: [String: String] {
        guard case .soundAssignments(let assignments)? = values["soundMap"] else { return [:] }
        return assignments
    }

    func soundName(for eventName: String) -> String? {
        let assignedName = soundAssignments[eventName] ?? eventName
        return assignedName == "off" ? nil : assignedName
    }

    var sharedWithHubValues: [String: SettingValue] {
        values.filter { SettingsSchema.definition(for: $0.key)?.scope == .sharedWithHub }
    }

    func displayText(for definition: SettingDefinition) -> String {
        switch values[definition.key] {
        case .text(let textValue):
            return "\(definition.label): \(textValue)"
        case .flag(let flagValue):
            return "\(definition.label): \(flagValue ? "on" : "off")"
        default:
            return definition.label
        }
    }

    private func textValue(_ key: String) -> String {
        guard case .text(let textValue)? = values[key] else { return "" }
        return textValue
    }

    private func flagValue(_ key: String) -> Bool {
        guard case .flag(let flagValue)? = values[key] else { return false }
        return flagValue
    }
}

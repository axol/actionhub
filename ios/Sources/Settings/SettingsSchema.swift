import Foundation

enum SettingsSchema {
    static let soundEvents = ["click", "sent", "delivered", "record", "stop", "tick", "think", "response", "failed"]

    static let definitions: [SettingDefinition] = [
        SettingDefinition(
            key: "mode",
            label: "mode",
            kind: .choice(["ptt", "vad"]),
            defaultValue: .text("ptt"),
            scope: .sharedWithHub,
            showableOnMain: true
        ),
        SettingDefinition(
            key: "sendPhraseEnabled",
            label: "send phrase",
            kind: .toggle,
            defaultValue: .flag(true),
            scope: .phoneOnly,
            showableOnMain: true
        ),
        SettingDefinition(
            key: "showDiscardButton",
            label: "discard button",
            kind: .toggle,
            defaultValue: .flag(true),
            scope: .phoneOnly,
            showableOnMain: false
        ),
        SettingDefinition(
            key: "showSendButton",
            label: "record/send button",
            kind: .toggle,
            defaultValue: .flag(true),
            scope: .phoneOnly,
            showableOnMain: false
        ),
        SettingDefinition(
            key: "showMuteButton",
            label: "mute button",
            kind: .toggle,
            defaultValue: .flag(true),
            scope: .phoneOnly,
            showableOnMain: false
        ),
        SettingDefinition(
            key: "soundMap",
            label: "sound effects",
            kind: .soundMap,
            defaultValue: .soundAssignments([:]),
            scope: .phoneOnly,
            showableOnMain: false
        ),
    ]

    static func definition(for key: String) -> SettingDefinition? {
        definitions.first { $0.key == key }
    }
}

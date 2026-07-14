import Foundation

enum SettingScope {
    case phoneOnly
    case sharedWithHub
}

enum SettingKind {
    case choice([String])
    case toggle
    case soundMap
}

enum SettingValue: Codable, Equatable {
    case text(String)
    case flag(Bool)
    case soundAssignments([String: String])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flagValue = try? container.decode(Bool.self) {
            self = .flag(flagValue)
        } else if let textValue = try? container.decode(String.self) {
            self = .text(textValue)
        } else {
            self = .soundAssignments(try container.decode([String: String].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let textValue):
            try container.encode(textValue)
        case .flag(let flagValue):
            try container.encode(flagValue)
        case .soundAssignments(let assignments):
            try container.encode(assignments)
        }
    }
}

struct SettingDefinition {
    let key: String
    let label: String
    let kind: SettingKind
    let defaultValue: SettingValue
    let scope: SettingScope
    let showableOnMain: Bool
}

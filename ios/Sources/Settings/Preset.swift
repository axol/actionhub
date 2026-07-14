import Foundation

struct Preset: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var values: [String: SettingValue]
    var mainPageKeys: [String]

    init(id: UUID = UUID(), name: String, values: [String: SettingValue] = [:], mainPageKeys: [String] = ["mode"]) {
        self.id = id
        self.name = name
        self.values = values
        self.mainPageKeys = mainPageKeys
    }
}

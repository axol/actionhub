import Foundation

@MainActor
final class SoundLibrary: ObservableObject {
    @Published private(set) var generatedSoundNames: [String] = []

    static let bundledSoundNames = SettingsSchema.soundEvents

    private let soundsDirectory: URL

    init() {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        soundsDirectory = documentsDirectory.appendingPathComponent("sounds")
        try? FileManager.default.createDirectory(at: soundsDirectory, withIntermediateDirectories: true)
        refresh()
    }

    var allSoundNames: [String] {
        Self.bundledSoundNames + generatedSoundNames.filter { !Self.bundledSoundNames.contains($0) }
    }

    func url(for soundName: String) -> URL? {
        let generatedUrl = soundsDirectory.appendingPathComponent("\(soundName).mp3")
        if FileManager.default.fileExists(atPath: generatedUrl.path) {
            return generatedUrl
        }
        return Bundle.main.url(forResource: soundName, withExtension: "mp3")
    }

    func saveGeneratedSound(named soundName: String, data soundData: Data) {
        let sanitizedName = Self.sanitize(soundName)
        guard !sanitizedName.isEmpty else { return }
        try? soundData.write(to: soundsDirectory.appendingPathComponent("\(sanitizedName).mp3"))
        refresh()
    }

    func deleteGeneratedSound(named soundName: String) {
        try? FileManager.default.removeItem(at: soundsDirectory.appendingPathComponent("\(soundName).mp3"))
        refresh()
    }

    private func refresh() {
        let fileUrls = (try? FileManager.default.contentsOfDirectory(at: soundsDirectory, includingPropertiesForKeys: nil)) ?? []
        generatedSoundNames = fileUrls
            .filter { $0.pathExtension == "mp3" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    private static func sanitize(_ soundName: String) -> String {
        soundName
            .lowercased()
            .map { character in character.isLetter || character.isNumber ? String(character) : "-" }
            .joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

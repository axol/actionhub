import SwiftUI

struct SoundStudioView: View {
    @ObservedObject var soundLibrary: SoundLibrary

    @State private var prompt = ""
    @State private var soundName = ""
    @State private var generatedData: Data?
    @State private var generating = false
    @State private var statusMessage = ""
    @State private var soundPlayer = SoundPlayer()

    var body: some View {
        Form {
            Section("prompt") {
                TextField("describe the sound", text: $prompt, axis: .vertical)
                    .lineLimit(2...4)
                Button(generating ? "generating..." : "generate") {
                    generate()
                }
                .disabled(generating || trimmedPrompt.isEmpty)
            }
            if let generatedData {
                Section("result") {
                    Button {
                        soundPlayer.play(data: generatedData)
                    } label: {
                        Label("play", systemImage: "play.circle")
                    }
                    TextField("sound name", text: $soundName)
                    Button("save") {
                        soundLibrary.saveGeneratedSound(named: soundName, data: generatedData)
                        statusMessage = "saved \(soundName)"
                        self.generatedData = nil
                        soundName = ""
                    }
                    .disabled(soundName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if !statusMessage.isEmpty {
                Section {
                    Text(statusMessage)
                        .foregroundStyle(.secondary)
                }
            }
            if !soundLibrary.generatedSoundNames.isEmpty {
                Section("generated sounds") {
                    ForEach(soundLibrary.generatedSoundNames, id: \.self) { generatedName in
                        HStack {
                            Text(generatedName)
                            Spacer()
                            Button {
                                if let soundUrl = soundLibrary.url(for: generatedName) {
                                    soundPlayer.play(soundUrl)
                                }
                            } label: {
                                Image(systemName: "play.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .onDelete { indexSet in
                        for soundIndex in indexSet {
                            soundLibrary.deleteGeneratedSound(named: soundLibrary.generatedSoundNames[soundIndex])
                        }
                    }
                }
            }
        }
        .navigationTitle("sound studio")
    }

    private var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func generate() {
        generating = true
        statusMessage = ""
        Task {
            do {
                generatedData = try await SoundGenerator().generate(prompt: trimmedPrompt)
            } catch {
                statusMessage = "generation failed"
            }
            generating = false
        }
    }
}

import AVFoundation

final class SoundPlayer {
    private var activePlayers: [AVAudioPlayer] = []

    func play(_ soundName: String) {
        guard let soundUrl = Bundle.main.url(forResource: soundName, withExtension: "mp3"),
              let soundPlayer = try? AVAudioPlayer(contentsOf: soundUrl) else { return }
        activePlayers.removeAll { !$0.isPlaying }
        activePlayers.append(soundPlayer)
        soundPlayer.play()
    }
}

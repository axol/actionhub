import AVFoundation

final class SoundPlayer {
    private var activePlayers: [AVAudioPlayer] = []

    func play(_ soundUrl: URL) {
        guard let soundPlayer = try? AVAudioPlayer(contentsOf: soundUrl) else { return }
        activePlayers.removeAll { !$0.isPlaying }
        activePlayers.append(soundPlayer)
        soundPlayer.play()
    }

    func play(data soundData: Data) {
        guard let soundPlayer = try? AVAudioPlayer(data: soundData) else { return }
        activePlayers.removeAll { !$0.isPlaying }
        activePlayers.append(soundPlayer)
        soundPlayer.play()
    }
}

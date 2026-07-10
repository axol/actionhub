import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

final class MicrophoneGate {
    var enabled = true
    var recording = false
    var speaking = false
}

@MainActor
final class WalkController: NSObject, ObservableObject {
    @Published var relayStatus = "relay: connecting..."
    @Published var scribeStatus = "scribe: off"
    @Published var activityStatus = "idle"
    @Published var eventLog: [String] = []
    @Published var walkAudioEnabled = true {
        didSet { applyWalkAudioSetting() }
    }

    private let relayClient = RelayClient()
    private let scribeStream = ScribeStream()
    private let audioPipeline = AudioPipeline()
    private let soundPlayer = SoundPlayer()
    private let microphoneGate = MicrophoneGate()
    private var silentPlayer: AVAudioPlayer?
    private var recording = false
    private var pendingSend = false
    private var speaking = false
    private var eventCounter = 0
    private var started = false

    func start() {
        if started { return }
        started = true
        wireRelay()
        wireScribe()
        wireAudioPipeline()
        do {
            try audioPipeline.start()
        } catch {
            appendLog("audio start failed: \(error.localizedDescription)")
        }
        startSilentAudio()
        registerRemoteCommands()
        publishNowPlaying()
        relayClient.connect()
        applyWalkAudioSetting()
    }

    private func wireRelay() {
        relayClient.onStatusChange = { [weak self] status in
            self?.relayStatus = status
        }
        relayClient.onOpen = { [weak self] in
            self?.relayClient.send(["type": "hello", "device": UIDevice.current.name])
        }
        relayClient.onMessage = { [weak self] payload in
            self?.handleHubMessage(payload)
        }
    }

    private func wireScribe() {
        scribeStream.onStatusChange = { [weak self] status in
            self?.scribeStatus = status
        }
        scribeStream.onPartial = { [weak self] text in
            self?.relayClient.send(["type": "utterance", "kind": "partial", "text": text])
        }
        scribeStream.onCommitted = { [weak self] text in
            self?.appendLog("committed: \(text)")
            self?.relayClient.send(["type": "utterance", "kind": "committed", "text": text])
        }
    }

    private func wireAudioPipeline() {
        let gate = microphoneGate
        let scribe = scribeStream
        audioPipeline.onMicrophoneChunk = { audioChunk in
            guard gate.enabled else { return }
            if gate.recording && !gate.speaking {
                scribe.sendAudio(audioChunk)
            } else {
                scribe.sendAudio(Data(count: audioChunk.count))
            }
        }
        audioPipeline.onPlaybackFinished = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.speaking = false
                self.microphoneGate.speaking = false
                self.refreshActivityStatus()
                self.relayClient.send(["type": "playback", "active": false])
            }
        }
    }

    private func handleHubMessage(_ payload: [String: Any]) {
        switch payload["type"] as? String {
        case "state":
            recording = payload["recording"] as? Bool ?? false
            pendingSend = payload["pending_send"] as? Bool ?? false
            microphoneGate.recording = recording
            refreshActivityStatus()
        case "sound":
            if let soundName = payload["name"] as? String {
                soundPlayer.play(soundName)
            }
        case "speak":
            if let text = payload["text"] as? String {
                speaking = true
                microphoneGate.speaking = true
                refreshActivityStatus()
                appendLog("speak: \(text)")
                relayClient.send(["type": "playback", "active": true])
                audioPipeline.speak(text)
            }
        case "stop_playback":
            audioPipeline.stopSpeaking()
        case "commit":
            scribeStream.commit()
        default:
            break
        }
    }

    private func refreshActivityStatus() {
        if pendingSend {
            activityStatus = "sending"
        } else if speaking {
            activityStatus = "speaking"
        } else if recording {
            activityStatus = "recording"
        } else {
            activityStatus = "idle"
        }
    }

    private func applyWalkAudioSetting() {
        microphoneGate.enabled = walkAudioEnabled
        if walkAudioEnabled {
            scribeStream.start()
        } else {
            scribeStream.stop()
        }
    }

    private func appendLog(_ line: String) {
        eventCounter += 1
        let timestamp = Date().formatted(date: .omitted, time: .standard)
        eventLog.append("\(eventCounter) \(timestamp) \(line)")
        if eventLog.count > 200 {
            eventLog.removeFirst(100)
        }
    }

    private func startSilentAudio() {
        silentPlayer = try? AVAudioPlayer(data: makeSilentWaveData())
        silentPlayer?.numberOfLoops = -1
        silentPlayer?.volume = 0
        silentPlayer?.play()
    }

    private func makeSilentWaveData() -> Data {
        let sampleRate = 8000
        let frameCount = sampleRate
        var waveData = Data()
        func appendValue<T>(_ value: T) {
            withUnsafeBytes(of: value) { waveData.append(contentsOf: $0) }
        }
        waveData.append(contentsOf: Array("RIFF".utf8))
        appendValue(UInt32(36 + frameCount * 2))
        waveData.append(contentsOf: Array("WAVE".utf8))
        waveData.append(contentsOf: Array("fmt ".utf8))
        appendValue(UInt32(16))
        appendValue(UInt16(1))
        appendValue(UInt16(1))
        appendValue(UInt32(sampleRate))
        appendValue(UInt32(sampleRate * 2))
        appendValue(UInt16(2))
        appendValue(UInt16(16))
        waveData.append(contentsOf: Array("data".utf8))
        appendValue(UInt32(frameCount * 2))
        waveData.append(Data(count: frameCount * 2))
        return waveData
    }

    private func registerRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()
        registerCommand(commandCenter.playCommand, named: "playCommand")
        registerCommand(commandCenter.pauseCommand, named: "pauseCommand")
        registerCommand(commandCenter.togglePlayPauseCommand, named: "togglePlayPauseCommand")
        registerCommand(commandCenter.stopCommand, named: "stopCommand")
        registerCommand(commandCenter.nextTrackCommand, named: "nextTrackCommand")
        registerCommand(commandCenter.previousTrackCommand, named: "previousTrackCommand")
        registerCommand(commandCenter.seekForwardCommand, named: "seekForwardCommand")
        registerCommand(commandCenter.seekBackwardCommand, named: "seekBackwardCommand")
    }

    private func registerCommand(_ command: MPRemoteCommand, named commandName: String) {
        command.isEnabled = true
        command.addTarget { [weak self] _ in
            DispatchQueue.main.async {
                self?.appendLog(commandName)
                self?.relayClient.send(["type": "command", "command": commandName])
            }
            return .success
        }
    }

    private func publishNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "actionhub",
            MPMediaItemPropertyArtist: "listening for controls",
            MPMediaItemPropertyPlaybackDuration: 3600.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
    }
}

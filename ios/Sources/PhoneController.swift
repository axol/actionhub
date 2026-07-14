import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

final class MicrophoneGate {
    var phoneOwnsAudio = true
    var recording = false
    var speaking = false
}

@MainActor
final class PhoneController: NSObject, ObservableObject {
    @Published var relayStatus = "relay: connecting..."
    @Published var scribeStatus = "scribe: off"
    @Published var activityStatus = "idle"
    @Published var audioOwner = "phone"
    @Published var muted = false
    @Published var eventLog: [String] = []

    let presetStore = PresetStore()
    let soundLibrary = SoundLibrary()
    let transcriptBuffer = TranscriptBuffer()

    private static let sendPhrase = "the message is now complete"
    private static let sendPhraseMatchThreshold = 0.8
    private static let sendDrainTimeoutSeconds = 2.5

    private let relayClient = RelayClient()
    private let scribeStream = ScribeStream()
    private let audioPipeline = AudioPipeline()
    private let soundPlayer = SoundPlayer()
    private let microphoneGate = MicrophoneGate()
    private var silentPlayer: AVAudioPlayer?
    private var recording = false
    private var sending = false
    private var speaking = false
    private var suppressedCommitCount = 0
    private var sendDrainTimeoutWorkItem: DispatchWorkItem?
    private var eventCounter = 0
    private var started = false

    func start() {
        if started { return }
        started = true
        wireRelay()
        wireScribe()
        wireAudioPipeline()
        wirePresets()
        wireTranscriptBuffer()
        do {
            try audioPipeline.start()
        } catch {
            appendLog("audio start failed: \(error.localizedDescription)")
        }
        startSilentAudio()
        registerRemoteCommands()
        publishNowPlaying()
        relayClient.connect()
        scribeStream.start()
        applyCaptureState()
    }

    func primaryAction() {
        appendLog("primary")
        if audioOwner != "phone" {
            takeAudio()
            startListening()
            return
        }
        if sending { return }
        if recording {
            beginSend()
        } else {
            startListening()
        }
    }

    func secondaryAction() {
        appendLog("secondary")
        if audioOwner != "phone" {
            takeAudio()
            applyCaptureState()
            return
        }
        if speaking {
            audioPipeline.stopSpeaking()
            startListening()
            return
        }
        if sending {
            cancelSend()
            return
        }
        if recording || !transcriptBuffer.isEmpty {
            discard()
        }
    }

    private func takeAudio() {
        audioOwner = "phone"
        microphoneGate.phoneOwnsAudio = true
        relayClient.send(["type": "take_audio"])
        scribeStream.start()
        appendLog("took audio")
    }

    func toggleMute() {
        muted.toggle()
        appendLog(muted ? "muted" : "unmuted")
        playLocalSound(muted ? "stop" : "record")
        refreshMicrophoneGate()
        refreshActivityStatus()
        sendStatus()
    }

    private func refreshMicrophoneGate() {
        microphoneGate.recording = recording && !muted && !sending
    }

    private func startListening() {
        guard !recording else { return }
        recording = true
        refreshMicrophoneGate()
        playLocalSound("record")
        refreshActivityStatus()
        sendStatus()
    }

    private func stopListening() {
        guard recording else { return }
        recording = false
        refreshMicrophoneGate()
        refreshActivityStatus()
        sendStatus()
    }

    private func suppressInFlightPartial() {
        guard !transcriptBuffer.livePartial.isEmpty else { return }
        suppressedCommitCount += 1
        scribeStream.commit()
    }

    private func discard() {
        suppressInFlightPartial()
        transcriptBuffer.clear()
        playLocalSound("stop")
        if presetStore.activeSettings.mode == "ptt" {
            stopListening()
        }
        refreshActivityStatus()
        sendStatus()
    }

    private func beginSend() {
        sending = true
        refreshMicrophoneGate()
        refreshActivityStatus()
        sendStatus()
        scribeStream.commit()
        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.completeSend()
        }
        sendDrainTimeoutWorkItem = timeoutWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.sendDrainTimeoutSeconds, execute: timeoutWorkItem)
        if transcriptBuffer.livePartial.isEmpty {
            completeSend()
        }
    }

    private func completeSend() {
        guard sending else { return }
        dispatchAssembledMessage()
    }

    private func cancelSend() {
        sending = false
        sendDrainTimeoutWorkItem?.cancel()
        sendDrainTimeoutWorkItem = nil
        suppressInFlightPartial()
        transcriptBuffer.clear()
        playLocalSound("stop")
        appendLog("send cancelled")
        refreshMicrophoneGate()
        applyCaptureState()
        refreshActivityStatus()
        sendStatus()
    }

    private func dispatchAssembledMessage() {
        sending = false
        sendDrainTimeoutWorkItem?.cancel()
        sendDrainTimeoutWorkItem = nil
        relayClient.send(["type": "message", "text": transcriptBuffer.assembledText])
        transcriptBuffer.clear()
        recording = false
        refreshMicrophoneGate()
        applyCaptureState()
        refreshActivityStatus()
        sendStatus()
    }

    private func applyCaptureState() {
        guard audioOwner == "phone", !sending else { return }
        let shouldListen = presetStore.activeSettings.mode == "vad"
        if shouldListen && !recording {
            startListening()
        } else if !shouldListen && recording {
            stopListening()
        }
    }

    private func wireRelay() {
        relayClient.onStatusChange = { [weak self] status in
            self?.relayStatus = status
        }
        relayClient.onOpen = { [weak self] in
            guard let self else { return }
            relayClient.send(["type": "hello", "device": UIDevice.current.name])
            sendStatus()
        }
        relayClient.onMessage = { [weak self] payload in
            self?.handleBridgeMessage(payload)
        }
    }

    private func wireScribe() {
        scribeStream.onStatusChange = { [weak self] status in
            self?.scribeStatus = status
        }
        scribeStream.onPartial = { [weak self] text in
            guard let self else { return }
            transcriptBuffer.livePartial = text.trimmingCharacters(in: .whitespacesAndNewlines)
            relayClient.send(["type": "utterance", "kind": "partial", "text": text])
        }
        scribeStream.onCommitted = { [weak self] text in
            self?.handleCommittedTranscript(text)
        }
    }

    private func wireAudioPipeline() {
        let gate = microphoneGate
        let scribe = scribeStream
        audioPipeline.onMicrophoneChunk = { audioChunk in
            guard gate.phoneOwnsAudio else { return }
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

    private func wirePresets() {
        presetStore.onSettingsChange = { [weak self] in
            self?.objectWillChange.send()
        }
        presetStore.onSharedSettingsChange = { [weak self] in
            guard let self else { return }
            applyCaptureState()
            sendStatus()
        }
    }

    private func wireTranscriptBuffer() {
        transcriptBuffer.onSegmentCountChange = { [weak self] _ in
            self?.sendStatus()
        }
    }

    private func sendStatus() {
        relayClient.send([
            "type": "status",
            "recording": recording && !muted,
            "sending": sending,
            "buffer": transcriptBuffer.segments.count,
            "mode": presetStore.activeSettings.mode,
        ])
    }

    private func handleCommittedTranscript(_ text: String) {
        transcriptBuffer.livePartial = ""
        if suppressedCommitCount > 0 {
            suppressedCommitCount -= 1
            return
        }
        relayClient.send(["type": "utterance", "kind": "committed", "text": text])
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedText.isEmpty {
            appendLog("committed: \(trimmedText)")
        }
        if presetStore.activeSettings.sendPhraseEnabled && Self.matchesSendPhrase(trimmedText) {
            dispatchAssembledMessage()
            return
        }
        if !trimmedText.isEmpty {
            transcriptBuffer.appendCommitted(trimmedText)
            playLocalSound("click")
        }
        if sending {
            completeSend()
        }
    }

    private static func matchesSendPhrase(_ text: String) -> Bool {
        let normalizedText = normalize(text)
        guard !normalizedText.isEmpty else { return false }
        return similarity(normalizedText, sendPhrase) >= sendPhraseMatchThreshold
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .filter { character in character.isLetter || character == " " }
            .trimmingCharacters(in: .whitespaces)
    }

    private static func similarity(_ leftText: String, _ rightText: String) -> Double {
        let leftCharacters = Array(leftText)
        let rightCharacters = Array(rightText)
        guard !leftCharacters.isEmpty && !rightCharacters.isEmpty else { return 0 }
        var previousRow = Array(0...rightCharacters.count)
        for leftIndex in 1...leftCharacters.count {
            var currentRow = [leftIndex]
            for rightIndex in 1...rightCharacters.count {
                let substitutionCost = leftCharacters[leftIndex - 1] == rightCharacters[rightIndex - 1] ? 0 : 1
                currentRow.append(min(
                    previousRow[rightIndex] + 1,
                    currentRow[rightIndex - 1] + 1,
                    previousRow[rightIndex - 1] + substitutionCost
                ))
            }
            previousRow = currentRow
        }
        let editDistance = Double(previousRow[rightCharacters.count])
        let maximumLength = Double(max(leftCharacters.count, rightCharacters.count))
        return 1 - editDistance / maximumLength
    }

    private func handleBridgeMessage(_ payload: [String: Any]) {
        switch payload["type"] as? String {
        case "state":
            let owner = payload["audio"] as? String ?? "phone"
            if owner != audioOwner {
                audioOwner = owner
                appendLog("audio owner: \(owner)")
                microphoneGate.phoneOwnsAudio = owner == "phone"
                if owner == "phone" {
                    scribeStream.start()
                    applyCaptureState()
                } else {
                    stopListening()
                    scribeStream.stop()
                }
            }
            refreshActivityStatus()
        case "activity":
            if let text = payload["text"] as? String {
                appendLog("claude: \(text)")
            }
        case "sound":
            if let eventName = payload["name"] as? String {
                playLocalSound(eventName)
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
        default:
            break
        }
    }

    private func playLocalSound(_ eventName: String) {
        guard let soundName = presetStore.activeSettings.soundName(for: eventName),
              let soundUrl = soundLibrary.url(for: soundName) else { return }
        soundPlayer.play(soundUrl)
    }

    private func refreshActivityStatus() {
        if sending {
            activityStatus = "sending"
        } else if speaking {
            activityStatus = "speaking"
        } else if muted && audioOwner == "phone" {
            activityStatus = "muted"
        } else if recording && audioOwner == "phone" {
            activityStatus = presetStore.activeSettings.mode == "vad" ? "listening" : "recording"
        } else {
            activityStatus = "idle"
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

    private func handleMediaCommand(_ commandName: String) {
        switch commandName {
        case "nextTrackCommand":
            primaryAction()
        case "previousTrackCommand":
            secondaryAction()
        default:
            appendLog(commandName)
        }
    }

    private func registerCommand(_ command: MPRemoteCommand, named commandName: String) {
        command.isEnabled = true
        command.addTarget { [weak self] _ in
            DispatchQueue.main.async {
                self?.handleMediaCommand(commandName)
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

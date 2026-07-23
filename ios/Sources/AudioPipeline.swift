import AVFoundation

final class AudioPipeline {
    var onMicrophoneChunk: ((Data) -> Void)?
    var onPlaybackFinished: (() -> Void)?

    private let audioEngine = AVAudioEngine()
    private let speechPlayerNode = AVAudioPlayerNode()
    private let speechFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
    private let scribeFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(ScribeStream.sampleRate), channels: 1, interleaved: true)!
    private var microphoneConverter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var speechTask: Task<Void, Never>?

    func start() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth, .allowBluetoothA2DP])
        try audioSession.setActive(true)
        audioEngine.attach(speechPlayerNode)
        audioEngine.connect(speechPlayerNode, to: audioEngine.mainMixerNode, format: speechFormat)
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handleMicrophoneBuffer(buffer)
        }
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            self?.restartEngineAfterConfigurationChange()
        }
        audioEngine.prepare()
        try audioEngine.start()
    }

    private func restartEngineAfterConfigurationChange() {
        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        let inputFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handleMicrophoneBuffer(buffer)
        }
        if !audioEngine.isRunning {
            audioEngine.prepare()
            try? audioEngine.start()
        }
    }

    func speak(_ text: String) {
        stopSpeaking()
        speechTask = Task { [weak self] in
            await self?.streamSpeech(text)
        }
    }

    func stopSpeaking() {
        speechTask?.cancel()
        speechTask = nil
        speechPlayerNode.stop()
    }

    private func handleMicrophoneBuffer(_ buffer: AVAudioPCMBuffer) {
        if microphoneConverter == nil || converterInputFormat != buffer.format {
            microphoneConverter = AVAudioConverter(from: buffer.format, to: scribeFormat)
            converterInputFormat = buffer.format
        }
        guard let microphoneConverter else { return }
        let sampleRateRatio = scribeFormat.sampleRate / buffer.format.sampleRate
        let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * sampleRateRatio) + 16
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: scribeFormat, frameCapacity: frameCapacity) else { return }
        var bufferConsumed = false
        let conversionStatus = microphoneConverter.convert(to: convertedBuffer, error: nil) { _, inputStatus in
            if bufferConsumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            bufferConsumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard conversionStatus != .error,
              convertedBuffer.frameLength > 0,
              let convertedSamples = convertedBuffer.int16ChannelData else { return }
        let audioChunk = Data(bytes: convertedSamples[0], count: Int(convertedBuffer.frameLength) * 2)
        onMicrophoneChunk?(audioChunk)
    }

    private func streamSpeech(_ text: String) async {
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/text-to-speech/CotBdG05uF4hQYtylCDX/stream?output_format=pcm_24000")!)
        request.httpMethod = "POST"
        request.setValue(elevenLabsApiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text, "model_id": "eleven_v3"])
        do {
            let (byteStream, _) = try await URLSession.shared.bytes(for: request)
            speechPlayerNode.play()
            var pcmChunk = Data()
            for try await pcmByte in byteStream {
                if Task.isCancelled { break }
                pcmChunk.append(pcmByte)
                if pcmChunk.count >= 9600 {
                    scheduleSpeechChunk(pcmChunk)
                    pcmChunk = Data()
                }
            }
            if !Task.isCancelled && !pcmChunk.isEmpty {
                scheduleSpeechChunk(pcmChunk)
            }
            if !Task.isCancelled {
                await waitForPlaybackDrain()
            }
        } catch {}
        onPlaybackFinished?()
    }

    private func scheduleSpeechChunk(_ pcmChunk: Data) {
        let frameCount = pcmChunk.count / 2
        guard frameCount > 0,
              let speechBuffer = AVAudioPCMBuffer(pcmFormat: speechFormat, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        speechBuffer.frameLength = AVAudioFrameCount(frameCount)
        pcmChunk.withUnsafeBytes { rawBuffer in
            let pcmSamples = rawBuffer.bindMemory(to: Int16.self)
            let floatChannel = speechBuffer.floatChannelData![0]
            for sampleIndex in 0..<frameCount {
                floatChannel[sampleIndex] = Float(pcmSamples[sampleIndex]) / 32768.0
            }
        }
        speechPlayerNode.scheduleBuffer(speechBuffer)
    }

    private func waitForPlaybackDrain() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            guard let drainMarker = AVAudioPCMBuffer(pcmFormat: speechFormat, frameCapacity: 1) else {
                continuation.resume()
                return
            }
            drainMarker.frameLength = 1
            speechPlayerNode.scheduleBuffer(drainMarker) {
                continuation.resume()
            }
        }
    }
}

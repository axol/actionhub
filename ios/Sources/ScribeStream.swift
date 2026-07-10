import Foundation

final class ScribeStream: NSObject, URLSessionWebSocketDelegate {
    static let sampleRate = 16000

    var onPartial: ((String) -> Void)?
    var onCommitted: ((String) -> Void)?
    var onStatusChange: ((String) -> Void)?

    private var webSocketTask: URLSessionWebSocketTask?
    private var enabled = false
    private lazy var urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: .main)

    func start() {
        enabled = true
        connect()
    }

    func stop() {
        enabled = false
        webSocketTask?.cancel()
        webSocketTask = nil
        onStatusChange?("scribe: off")
    }

    func sendAudio(_ audioData: Data, commit: Bool = false) {
        guard let webSocketTask else { return }
        let payload: [String: Any] = [
            "message_type": "input_audio_chunk",
            "audio_base_64": audioData.base64EncodedString(),
            "commit": commit,
            "sample_rate": Self.sampleRate,
        ]
        guard let payloadData = try? JSONSerialization.data(withJSONObject: payload),
              let payloadText = String(data: payloadData, encoding: .utf8) else { return }
        webSocketTask.send(.string(payloadText)) { _ in }
    }

    func commit() {
        sendAudio(Data(count: Self.sampleRate / 10 * 2), commit: true)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocolName: String?) {
        onStatusChange?("scribe: connected")
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        handleDisconnect("closed \(closeCode.rawValue)")
    }

    private func connect() {
        guard enabled, webSocketTask == nil else { return }
        let urlText = "wss://api.elevenlabs.io/v1/speech-to-text/realtime"
            + "?model_id=scribe_v2_realtime"
            + "&audio_format=pcm_\(Self.sampleRate)"
            + "&commit_strategy=vad"
            + "&vad_silence_threshold_secs=1.0"
        guard let scribeUrl = URL(string: urlText) else { return }
        var request = URLRequest(url: scribeUrl)
        request.setValue(elevenLabsApiKey, forHTTPHeaderField: "xi-api-key")
        let task = urlSession.webSocketTask(with: request)
        webSocketTask = task
        onStatusChange?("scribe: connecting...")
        receiveLoop(task)
        task.resume()
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            switch result {
            case .success(let message):
                if case .string(let text) = message {
                    self?.handleServerMessage(text)
                }
                self?.receiveLoop(task)
            case .failure(let receiveError):
                self?.handleDisconnect(receiveError.localizedDescription)
            }
        }
    }

    private func handleServerMessage(_ text: String) {
        guard let messageData = text.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any] else { return }
        let transcriptText = payload["text"] as? String ?? ""
        switch payload["message_type"] as? String {
        case "partial_transcript":
            onPartial?(transcriptText)
        case "committed_transcript":
            onCommitted?(transcriptText)
        default:
            break
        }
    }

    private func handleDisconnect(_ reason: String) {
        DispatchQueue.main.async {
            guard self.webSocketTask != nil else { return }
            self.webSocketTask?.cancel()
            self.webSocketTask = nil
            guard self.enabled else { return }
            self.onStatusChange?("scribe: disconnected, retrying...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.connect()
            }
        }
    }
}

import Foundation

final class RelayClient: NSObject, URLSessionWebSocketDelegate {
    var onOpen: (() -> Void)?
    var onMessage: (([String: Any]) -> Void)?
    var onStatusChange: ((String) -> Void)?

    private var webSocketTask: URLSessionWebSocketTask?
    private var presenceTimer: Timer?
    private lazy var urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: .main)

    func connect() {
        guard webSocketTask == nil else { return }
        guard let relayUrl = URL(string: "wss://relay.babelbase.com/?role=phone&room=actionhub&token=\(relayToken)") else { return }
        let task = urlSession.webSocketTask(with: relayUrl)
        webSocketTask = task
        onStatusChange?("relay: connecting...")
        receiveLoop(task)
        task.resume()
    }

    func send(_ payload: [String: Any]) {
        guard let webSocketTask else { return }
        guard let payloadData = try? JSONSerialization.data(withJSONObject: payload),
              let payloadText = String(data: payloadData, encoding: .utf8) else { return }
        webSocketTask.send(.string(payloadText)) { _ in }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocolName: String?) {
        onStatusChange?("relay: connected")
        startPresence()
        onOpen?()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        handleDisconnect("closed \(closeCode.rawValue)")
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            switch result {
            case .success(let message):
                if case .string(let text) = message,
                   let messageData = text.data(using: .utf8),
                   let payload = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any] {
                    self?.onMessage?(payload)
                }
                self?.receiveLoop(task)
            case .failure(let receiveError):
                self?.handleDisconnect(receiveError.localizedDescription)
            }
        }
    }

    private func handleDisconnect(_ reason: String) {
        DispatchQueue.main.async {
            guard self.webSocketTask != nil else { return }
            self.onStatusChange?("relay: disconnected, retrying...")
            self.presenceTimer?.invalidate()
            self.presenceTimer = nil
            self.webSocketTask?.cancel()
            self.webSocketTask = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.connect()
            }
        }
    }

    private func startPresence() {
        presenceTimer?.invalidate()
        presenceTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.send(["type": "presence"])
        }
    }
}

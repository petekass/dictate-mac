import Foundation

enum RealtimeError: LocalizedError {
    case server(type: String, message: String)
    case handshake(status: Int?, underlying: String)
    case closed(code: Int, reason: String)
    case timedOut
    case cancelled

    var errorDescription: String? {
        switch self {
        case .server(let type, let message):
            return "\(type): \(message)"
        case .handshake(let status, let underlying):
            if let status {
                return "connection refused (HTTP \(status))" + (status == 401 ? ", check the ElevenLabs API key" : "")
            }
            return "connection failed: \(underlying)"
        case .closed(let code, let reason):
            return "connection closed (\(code)\(reason.isEmpty ? "" : ": \(reason)"))"
        case .timedOut:
            return "no final transcript in time"
        case .cancelled:
            return "cancelled"
        }
    }
}

/// Streams 16 kHz mono Int16 PCM to ElevenLabs Scribe v2 Realtime over a WebSocket.
///
/// Lifecycle: `start()` when the hotkey goes down, `append(_:)` from the audio tap,
/// `finish(timeout:)` when it goes up (commits and waits for the final segment),
/// `cancel()` on every other exit path. All state lives on a private serial queue;
/// callbacks are delivered on the main queue.
final class RealtimeTranscriber: NSObject, URLSessionWebSocketDelegate {
    struct Options {
        var apiKey: String
        var languageCode: String?
        var keyterms: [String]
    }

    /// Called on the main queue with the text committed so far and the live partial.
    var onUpdate: ((_ committed: String, _ partial: String) -> Void)?
    /// Called once on the main queue when the stream fails while recording.
    var onFailure: ((Error) -> Void)?

    private let options: Options
    private let queue = DispatchQueue(label: "dictate.realtime")
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?

    private var pending: [Int16] = []
    private var sessionStarted = false
    private var finishRequested = false
    private var commitSent = false
    private var commitsSent = 0
    private var commitsReceived = 0
    private var samplesSinceCommit = 0
    private var hadIntermediateCommit = false
    private var quietChunks = 0
    private var done = false
    private var committed: [String] = []
    private var partial = ""
    private var failure: Error?
    private var continuation: CheckedContinuation<Result, Error>?

    /// 0.1 s at 16 kHz, the low end of the documented 0.1–1 s chunk range.
    private let chunkSamples = 1600
    /// Audio buffered while the socket opens; beyond this something is wrong.
    private let maxBufferedSamples = 16000 * 20
    /// The server only keeps roughly the last 25 s of an uncommitted segment and drops
    /// older speech (a hard commit at 28 s lost a whole sentence in testing), so long
    /// dictations commit in a pause after 15 s, at the latest at 20 s.
    private let softCommitSamples = 16000 * 15
    private let hardCommitSamples = 16000 * 20
    private let quietRMS: Double = 400

    static let maxKeyterms = 50
    static let maxKeytermLength = 20

    init(options: Options) {
        self.options = options
        super.init()
    }

    static func url(languageCode: String?, keyterms: [String]) -> URL {
        var components = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
        var items = [
            URLQueryItem(name: "model_id", value: "scribe_v2_realtime"),
            URLQueryItem(name: "audio_format", value: "pcm_16000"),
            URLQueryItem(name: "commit_strategy", value: "manual"),
        ]
        if let languageCode, !languageCode.isEmpty {
            items.append(URLQueryItem(name: "language_code", value: languageCode))
        }
        for term in usableKeyterms(keyterms) {
            items.append(URLQueryItem(name: "keyterms", value: term))
        }
        components.queryItems = items
        return components.url!
    }

    /// The realtime API accepts at most 50 keyterms of 20 characters each; the newest win,
    /// so recently learned terms are not the first to be dropped.
    static func usableKeyterms(_ terms: [String]) -> [String] {
        Array(terms.filter { !$0.isEmpty && $0.count <= maxKeytermLength }.suffix(maxKeyterms))
    }

    func start() {
        var request = URLRequest(url: Self.url(languageCode: options.languageCode, keyterms: options.keyterms))
        request.setValue(options.apiKey, forHTTPHeaderField: "xi-api-key")
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        queue.sync {
            self.session = session
            self.task = task
            task.resume()
            self.receive()
        }
    }

    /// Safe to call from the audio thread: only copies samples onto the queue.
    func append(_ samples: [Int16]) {
        queue.async {
            guard !self.done, !self.finishRequested else { return }
            self.pending.append(contentsOf: samples)
            if !self.sessionStarted && self.pending.count > self.maxBufferedSamples {
                self.fail(RealtimeError.timedOut)
                return
            }
            self.flush(commit: false)
        }
    }

    struct Result {
        let text: String
        /// True when the stream was committed before the end (dictations over ~15 s). After
        /// such a commit the server sometimes returned nothing for the rest of the audio
        /// (seen with microphone audio and with loud noise), so the caller should not trust
        /// `text` and should transcribe the full recording instead.
        let hadIntermediateCommit: Bool
    }

    /// Commits the last segment and returns the whole transcript.
    func finish(timeout: TimeInterval) async throws -> Result {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result, Error>) in
            queue.async {
                if let failure = self.failure {
                    continuation.resume(throwing: failure)
                    return
                }
                guard !self.done else {
                    continuation.resume(throwing: RealtimeError.cancelled)
                    return
                }
                self.continuation = continuation
                self.finishRequested = true
                if self.sessionStarted {
                    self.sendCommit()
                }
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    if self.continuation != nil {
                        self.fail(RealtimeError.timedOut)
                    }
                }
            }
        }
    }

    func cancel() {
        queue.async {
            guard !self.done else { return }
            self.done = true
            self.close()
            self.continuation?.resume(throwing: RealtimeError.cancelled)
            self.continuation = nil
        }
    }

    // MARK: - Queue-confined helpers

    private func flush(commit: Bool) {
        guard sessionStarted else { return }
        while pending.count >= chunkSamples || (commit && !pending.isEmpty) {
            // Long buffers (audio held back while connecting) go out in 1 s pieces.
            let count = min(pending.count, 16000)
            let chunk = Array(pending.prefix(count))
            pending.removeFirst(count)
            samplesSinceCommit += chunk.count
            let isFinal = commit && pending.isEmpty
            quietChunks = Self.rms(chunk) < quietRMS ? quietChunks + 1 : 0
            // A pause is 0.3 s of quiet (three chunks); a single quiet chunk is often just
            // the gap between two words.
            let isIntermediate = !commit && (samplesSinceCommit >= hardCommitSamples
                || (samplesSinceCommit >= softCommitSamples && quietChunks >= 3))
            if isIntermediate { hadIntermediateCommit = true }
            send(chunk, commit: isFinal || isIntermediate)
            if isFinal || isIntermediate {
                commitsSent += 1
                samplesSinceCommit = 0
            }
        }
    }

    private static func rms(_ samples: [Int16]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (sum / Double(samples.count)).squareRoot()
    }

    private func sendCommit() {
        guard !commitSent else { return }
        commitSent = true
        // The server rejects a commit with less than 0.3 s of uncommitted audio
        // (commit_throttled), e.g. right after an intermediate commit; pad with silence.
        // A commit also has to ride on an audio chunk, so never leave the buffer empty.
        let minimumUncommitted = 5600
        var padding = max(0, minimumUncommitted - samplesSinceCommit - pending.count)
        if pending.isEmpty {
            padding = max(padding, 800)
        }
        pending.append(contentsOf: repeatElement(0, count: padding))
        flush(commit: true)
    }

    private func send(_ samples: [Int16], commit: Bool) {
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let message: [String: Any] = [
            "message_type": "input_audio_chunk",
            "audio_base_64": data.base64EncodedString(),
            "commit": commit,
            "sample_rate": 16000,
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: json, encoding: .utf8) else { return }
        task?.send(.string(text)) { [weak self] error in
            guard let self, let error else { return }
            self.queue.async { self.fail(self.connectionError(error)) }
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard !self.done else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self.handle(text)
                    case .data(let data):
                        self.handle(String(decoding: data, as: UTF8.self))
                    @unknown default:
                        break
                    }
                    if !self.done { self.receive() }
                case .failure(let error):
                    self.fail(self.connectionError(error))
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["message_type"] as? String else { return }

        switch type {
        case "session_started":
            sessionStarted = true
            if finishRequested {
                sendCommit()
            } else {
                flush(commit: false)
            }
        case "partial_transcript":
            partial = (json["text"] as? String) ?? ""
            notify()
        case "committed_transcript":
            let segment = ((json["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !segment.isEmpty { committed.append(segment) }
            partial = ""
            commitsReceived += 1
            notify()
            // Intermediate commits may still be in flight when the final one goes out.
            if commitSent, commitsReceived >= commitsSent, let continuation {
                self.continuation = nil
                done = true
                close()
                continuation.resume(returning: Result(text: transcript, hadIntermediateCommit: hadIntermediateCommit))
            }
        case "warning":
            appLog.notice("realtime warning: \((json["warning"] as? String) ?? "unknown", privacy: .public)")
        default:
            if let message = json["error"] as? String {
                fail(RealtimeError.server(type: type, message: message))
            }
        }
    }

    private var transcript: String {
        committed.joined(separator: " ")
    }

    private func notify() {
        let committedText = transcript
        let partialText = partial
        DispatchQueue.main.async { self.onUpdate?(committedText, partialText) }
    }

    private func fail(_ error: Error) {
        guard failure == nil, !done else { return }
        failure = error
        done = true
        close()
        if let continuation {
            self.continuation = nil
            continuation.resume(throwing: error)
        } else {
            DispatchQueue.main.async { self.onFailure?(error) }
        }
    }

    private func connectionError(_ error: Error) -> Error {
        if let status = (task?.response as? HTTPURLResponse)?.statusCode, status != 101 {
            return RealtimeError.handshake(status: status, underlying: error.localizedDescription)
        }
        if let task, task.closeCode != .invalid {
            let reason = task.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? ""
            return RealtimeError.closed(code: task.closeCode.rawValue, reason: reason)
        }
        return RealtimeError.handshake(status: nil, underlying: error.localizedDescription)
    }

    private func close() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.finishTasksAndInvalidate()
        session = nil
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        queue.async {
            let text = reason.map { String(decoding: $0, as: UTF8.self) } ?? ""
            self.fail(RealtimeError.closed(code: closeCode.rawValue, reason: text))
        }
    }
}

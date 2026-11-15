import Foundation
import AVFoundation
import AppKit
import Combine
import UserNotifications
import os

/// Public log lines (readable in Console / `log show`). Never pass dictated text here.
let appLog = Logger(subsystem: "com.local.dictate", category: "app")

enum Language: String, CaseIterable {
    case auto = ""
    case de = "de"
    case en = "en"
}

enum DictationHotkey: String, CaseIterable {
    case leftOption = "left_option"
    case fn = "fn"

    var label: String {
        switch self {
        case .leftOption:
            return "Left Option"
        case .fn:
            return "Fn"
        }
    }

    var holdLabel: String {
        switch self {
        case .leftOption:
            return "⌥"
        case .fn:
            return "Fn"
        }
    }
}

enum TranscriptionProvider: String, CaseIterable {
    case groq = "groq"
    case elevenLabs = "elevenlabs"
    case elevenLabsLive = "elevenlabs_live"

    var label: String {
        switch self {
        case .groq:
            return "Groq Whisper"
        case .elevenLabs:
            return "ElevenLabs Scribe"
        case .elevenLabsLive:
            return "ElevenLabs Live"
        }
    }

    var shortName: String {
        switch self {
        case .groq:
            return "Groq"
        case .elevenLabs:
            return "ElevenLabs"
        case .elevenLabsLive:
            return "ElevenLabs Live"
        }
    }

    /// The provider whose API key this engine uses; ElevenLabs Live shares the Scribe key.
    var keyProvider: TranscriptionProvider {
        self == .elevenLabsLive ? .elevenLabs : self
    }

    var keyFileName: String {
        switch self {
        case .groq:
            return ".groq-api-key"
        case .elevenLabs, .elevenLabsLive:
            return ".elevenlabs-api-key"
        }
    }

    var environmentKey: String {
        switch self {
        case .groq:
            return "GROQ_API_KEY"
        case .elevenLabs, .elevenLabsLive:
            return "ELEVENLABS_API_KEY"
        }
    }

    var keyHint: String {
        switch self {
        case .groq:
            return "Get a free key at console.groq.com/keys"
        case .elevenLabs, .elevenLabsLive:
            return "Create a key at elevenlabs.io/app/settings/api-keys (needs Speech to Text access)"
        }
    }
}

/// Last problem shown in the menu bar until the next clean dictation or dismissal.
struct DictateIssue: Equatable {
    let message: String
    let isWarning: Bool
    let date: Date
}

@MainActor
class DictateManager: ObservableObject {
    // MARK: - Published State
    @Published var isRecording = false
    @Published var isProcessing = false
    /// Recording continues after the hotkey is released; the next press stops it.
    @Published private(set) var isHandsFree = false
    /// Set by the hotkey handler; read by the keyboard tap (hold hotkey + Space = hands-free).
    var hotkeyHeld = false
    @Published var history: [String] = []
    @Published var vocabulary: [String] = []
    @Published var autoCorrect: Bool = false {
        didSet { saveConfig() }
    }
    @Published var saveToClipboard: Bool = false {
        didSet { saveConfig() }
    }
    @Published var language: Language = .auto {
        didSet { saveConfig() }
    }
    @Published var hotkey: DictationHotkey = .leftOption {
        didSet { saveConfig() }
    }
    @Published var provider: TranscriptionProvider = .groq {
        didSet { saveConfig() }
    }
    @Published private(set) var lastIssue: DictateIssue?

    // MARK: - Computed Properties
    var statusIcon: String {
        if isRecording { return "waveform.circle.fill" }
        if isProcessing { return "ellipsis.circle" }
        if lastIssue != nil { return "exclamationmark.triangle.fill" }
        return "waveform"
    }

    var statusText: String {
        if isRecording { return "Recording…" }
        if isProcessing { return "Processing…" }
        return "Hold \(hotkey.holdLabel) to dictate"
    }

    var hasApiKey: Bool {
        hasApiKey(for: provider)
    }

    func hasApiKey(for provider: TranscriptionProvider) -> Bool {
        apiKeys[provider.keyProvider] != nil
    }

    // MARK: - Private
    private let audioRecorder = AudioRecorder()
    private let livePreview = LivePreviewPanel()
    private var liveTranscriber: RealtimeTranscriber?
    private let liveFinishTimeout: TimeInterval = 4
    private var dictationID = 0
    private var cancelRequested = false
    /// A forgotten hands-free recording must not run (and bill) forever.
    private let handsFreeLimit: TimeInterval = 10 * 60
    private var apiKeys: [TranscriptionProvider: String] = [:]
    private let requestTimeout: TimeInterval = 30
    private let configPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".dictate-config.json")
    private let vocabPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".dictate-vocab.json")

    private let historyMax = 5

    // MARK: - Init
    init() {
        loadApiKeys()
        loadConfig()
        loadVocabulary()
        requestNotificationPermission()
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                appLog.error("notification authorization failed: \(error.localizedDescription, privacy: .public)")
            } else if !granted {
                appLog.notice("notifications not allowed; errors are shown in the menu bar only")
            }
        }
    }

    // MARK: - API Keys
    private func apiKeyPath(for provider: TranscriptionProvider) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(provider.keyFileName)
    }

    private func loadApiKeys() {
        for provider in TranscriptionProvider.allCases where provider.keyProvider == provider {
            if let envKey = ProcessInfo.processInfo.environment[provider.environmentKey], !envKey.isEmpty {
                apiKeys[provider] = envKey
            } else if let key = try? String(contentsOf: apiKeyPath(for: provider), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !key.isEmpty {
                apiKeys[provider] = key
            }
        }
    }

    func setApiKey(_ key: String, for engine: TranscriptionProvider) {
        let provider = engine.keyProvider
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let path = apiKeyPath(for: provider)
        do {
            try trimmed.write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        } catch {
            reportIssue("Could not save \(provider.shortName) API key: \(error.localizedDescription)")
        }
        apiKeys[provider] = trimmed
        objectWillChange.send()
    }

    // MARK: - Config
    private func loadConfig() {
        guard let data = try? Data(contentsOf: configPath),
              let config = try? JSONDecoder().decode(Config.self, from: data) else {
            return
        }
        autoCorrect = config.correct
        saveToClipboard = config.saveToClipboard
        language = Language(rawValue: config.language ?? "") ?? .auto
        hotkey = DictationHotkey(rawValue: config.hotkey ?? "") ?? .leftOption
        provider = TranscriptionProvider(rawValue: config.provider ?? "") ?? .groq
    }

    private func saveConfig() {
        let config = Config(
            correct: autoCorrect,
            language: language.rawValue.isEmpty ? nil : language.rawValue,
            saveToClipboard: saveToClipboard,
            hotkey: hotkey.rawValue,
            provider: provider.rawValue
        )
        do {
            let data = try JSONEncoder().encode(config)
            try data.write(to: configPath)
        } catch {
            appLog.error("saving config failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Vocabulary
    private func loadVocabulary() {
        guard let data = try? Data(contentsOf: vocabPath),
              let vocab = try? JSONDecoder().decode(Vocabulary.self, from: data) else {
            return
        }
        vocabulary = vocab.terms
    }

    private func saveVocabulary() {
        let vocab = Vocabulary(terms: vocabulary)
        if let data = try? JSONEncoder().encode(vocab) {
            try? data.write(to: vocabPath)
        }
    }

    func addTerm(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !vocabulary.contains(trimmed) else { return }
        vocabulary.append(trimmed)
        saveVocabulary()
    }

    func removeTerm(_ term: String) {
        vocabulary.removeAll { $0 == term }
        saveVocabulary()
    }

    func setVocabulary(_ terms: [String]) {
        vocabulary = terms
        saveVocabulary()
    }

    // MARK: - Issues
    /// Makes a problem visible: menu bar icon, menu row, sound, notification (if allowed) and log.
    func reportIssue(_ message: String, warning: Bool = false) {
        appLog.error("\(warning ? "warning" : "error", privacy: .public): \(message, privacy: .public)")
        lastIssue = DictateIssue(message: message, isWarning: warning, date: Date())
        if warning {
            SoundGenerator.shared.playWarningSound()
        } else {
            SoundGenerator.shared.playErrorSound()
        }
        showNotification(title: warning ? "Dictate Warning" : "Dictate Error", body: message)
    }

    func dismissIssue() {
        lastIssue = nil
    }

    // MARK: - Recording
    func startRecording() {
        guard !isRecording, !isProcessing else { return }

        guard hasApiKey else {
            reportIssue("\(provider.shortName) API key missing. Open the menu and set it.")
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            reportIssue("Microphone permission requested. Try again once granted.", warning: true)
            return
        case .denied, .restricted:
            reportIssue("Microphone access denied. Enable Dictate in System Settings → Privacy & Security → Microphone.")
            return
        @unknown default:
            reportIssue("Unknown microphone permission state.")
            return
        }

        dictationID += 1
        cancelRequested = false
        isHandsFree = false
        isRecording = true
        playStartSound()
        if provider == .elevenLabsLive {
            startLiveTranscription()
        }
        audioRecorder.startRecording()
    }

    private func startLiveTranscription() {
        guard let apiKey = apiKeys[.elevenLabs] else { return }
        let transcriber = RealtimeTranscriber(options: .init(
            apiKey: apiKey,
            languageCode: language.rawValue.isEmpty ? nil : language.rawValue,
            keyterms: vocabulary
        ))
        transcriber.onUpdate = { [weak self, weak transcriber] committed, partial in
            guard let self, let transcriber, self.liveTranscriber === transcriber else { return }
            self.livePreview.update(committed: committed, partial: partial)
        }
        transcriber.onFailure = { [weak self, weak transcriber] error in
            guard let self, let transcriber, self.liveTranscriber === transcriber else { return }
            appLog.error("live stream failed while recording: \(error.localizedDescription, privacy: .public)")
            self.livePreview.setNote("Live preview lost, transcribing on release")
        }
        liveTranscriber = transcriber
        audioRecorder.onSamples = { [weak transcriber] samples in
            transcriber?.append(samples)
        }
        transcriber.start()
        livePreview.show()
    }

    /// Runs on every exit path of a dictation so no socket or panel outlives it.
    private func endLiveTranscription() {
        audioRecorder.onSamples = nil
        liveTranscriber?.cancel()
        liveTranscriber = nil
        livePreview.hide()
    }

    /// Hold hotkey + Space: keep recording after release until the hotkey is pressed again.
    func enterHandsFree() {
        guard isRecording, !isHandsFree else { return }
        isHandsFree = true
        if liveTranscriber == nil {
            livePreview.show()
        }
        livePreview.setHandsFree(hint: "hands-free, press \(hotkey.holdLabel) to finish, Esc to cancel")
        let id = dictationID
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.handsFreeLimit ?? 600) * 1_000_000_000))
            guard let self, self.dictationID == id, self.isRecording, self.isHandsFree else { return }
            self.stopRecording()
            self.reportIssue("Hands-free recording stopped after \(Int(self.handsFreeLimit / 60)) minutes.", warning: true)
        }
    }

    /// Esc: drops the recording, or stops a running transcription before anything is pasted.
    func cancelDictation() {
        if isRecording {
            isRecording = false
            isHandsFree = false
            _ = audioRecorder.stopRecording()
            endLiveTranscription()
            playStopSound()
            appLog.notice("dictation cancelled while recording")
        } else if isProcessing {
            cancelRequested = true
            endLiveTranscription()
            playStopSound()
            appLog.notice("dictation cancelled while transcribing")
        }
    }

    func stopRecording() {
        guard isRecording else { return }

        isRecording = false
        isHandsFree = false
        isProcessing = true
        playStopSound()

        Task {
            await processRecording()
        }
    }

    private func processRecording() async {
        defer {
            endLiveTranscription()
            isProcessing = false
        }

        guard let audioData = audioRecorder.stopRecording() else {
            reportIssue("No audio recorded. Check the microphone input.")
            return
        }

        // Check minimum duration (0.3 seconds at 16kHz = 4800 samples)
        if audioData.count < 4800 {
            reportIssue("Recording too short. Hold \(hotkey.holdLabel) a bit longer.", warning: true)
            return
        }

        var text: String
        var warning: String?
        if let transcriber = liveTranscriber {
            livePreview.setFinishing()
            do {
                let result = try await transcriber.finish(timeout: liveFinishTimeout)
                text = result.text
                if result.forcedMidSpeechCommit {
                    // Rare (20 s of speech without a pause); the stream may have lost the tail.
                    appLog.notice("live stream committed mid-speech, using batch transcription")
                    do {
                        text = try await transcribeBatch(audioData, with: .elevenLabs)
                    } catch {
                        warning = "Batch check failed (\(Self.describe(error))). Pasted the live transcript, which may miss words."
                    }
                }
            } catch {
                if cancelRequested { return }
                // The full recording is still here, so a failed stream costs only time.
                appLog.error("live transcription failed, falling back to batch: \(error.localizedDescription, privacy: .public)")
                do {
                    text = try await transcribeBatch(audioData, with: .elevenLabs)
                    warning = "Live transcription failed (\(Self.describe(error))). Used the normal ElevenLabs transcription instead."
                } catch let batchError {
                    reportIssue("Transcription failed (ElevenLabs): \(Self.describe(batchError))")
                    return
                }
            }
        } else {
            do {
                text = try await transcribeBatch(audioData, with: provider)
            } catch {
                reportIssue("Transcription failed (\(provider.shortName)): \(Self.describe(error))")
                return
            }
        }

        if cancelRequested { return }

        guard !text.isEmpty else {
            reportIssue("\(provider.shortName) returned no text. Nothing was pasted.", warning: true)
            return
        }

        if autoCorrect {
            if apiKeys[.groq] == nil {
                warning = Self.joinWarnings(warning, "Auto-Correct skipped: no Groq API key. Raw text was pasted.")
            } else {
                do {
                    text = try await correctText(text)
                } catch {
                    warning = Self.joinWarnings(warning, "Auto-Correct skipped (\(Self.describe(error))). Raw text was pasted.")
                }
            }
        }

        if cancelRequested { return }

        history.insert(text, at: 0)
        if history.count > historyMax {
            history.removeLast()
        }

        livePreview.hide()
        if let pasteError = pasteText(text, keepInClipboard: saveToClipboard) {
            reportIssue(pasteError)
            return
        }

        if let warning {
            reportIssue(warning, warning: true)
        } else {
            lastIssue = nil
        }
    }

    /// Pastes via Cmd+V. Returns an error message when pasting could not be triggered.
    private func pasteText(_ text: String, keepInClipboard: Bool) -> String? {
        guard !text.isEmpty else { return nil }

        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard AXIsProcessTrusted() else {
            return "Accessibility permission missing, so the text could not be pasted. It is in the clipboard and in History. Enable Dictate in System Settings → Privacy & Security → Accessibility."
        }

        Thread.sleep(forTimeInterval: 0.1)

        let process = Process()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application \"System Events\" to keystroke \"v\" using command down"]
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return "Paste failed: \(error.localizedDescription). The text is in the clipboard and in History."
        }

        if process.terminationStatus != 0 {
            let detail = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return "Paste failed (\(detail.isEmpty ? "osascript exit \(process.terminationStatus)" : detail)). The text is in the clipboard and in History. Allow Dictate to control System Events in System Settings → Privacy & Security → Automation."
        }

        guard !keepInClipboard else { return nil }

        // Restore the previous clipboard after the paste went through.
        Thread.sleep(forTimeInterval: 0.15)
        pasteboard.clearContents()
        pasteboard.setString(previous ?? "", forType: .string)
        return nil
    }

    // MARK: - Transcription APIs
    private func transcribeBatch(_ audioData: [Int16], with provider: TranscriptionProvider) async throws -> String {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try writeWAV(audioData: audioData, to: tempURL)
        switch provider {
        case .groq:
            return try await transcribeWithGroq(audioURL: tempURL)
        case .elevenLabs, .elevenLabsLive:
            return try await transcribeWithElevenLabs(audioURL: tempURL)
        }
    }

    private func transcribeWithGroq(audioURL: URL) async throws -> String {
        guard let apiKey = apiKeys[.groq] else {
            throw DictateError.noApiKey(.groq)
        }

        var form = MultipartForm()
        form.addField("model", "whisper-large-v3-turbo")
        form.addField("response_format", "text")
        if !language.rawValue.isEmpty {
            form.addField("language", language.rawValue)
        }
        if !vocabulary.isEmpty {
            form.addField("prompt", "Context terms: " + vocabulary.joined(separator: ", ") + ".")
        }
        form.addFile("file", filename: "audio.wav", contentType: "audio/wav", data: try Data(contentsOf: audioURL))

        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.finalized()

        let data = try await send(request, provider: .groq)
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func transcribeWithElevenLabs(audioURL: URL) async throws -> String {
        let audio = try Data(contentsOf: audioURL)
        do {
            return try await elevenLabsRequest(audio: audio, includeKeyterms: true)
        } catch DictateError.apiError(_, let status, let body) where status == 400 && body.contains("keyword") {
            // A vocabulary term ElevenLabs rejects must not block the dictation.
            appLog.error("ElevenLabs rejected keyterms, retrying without: \(body, privacy: .public)")
            return try await elevenLabsRequest(audio: audio, includeKeyterms: false)
        }
    }

    private func elevenLabsRequest(audio: Data, includeKeyterms: Bool) async throws -> String {
        guard let apiKey = apiKeys[.elevenLabs] else {
            throw DictateError.noApiKey(.elevenLabs)
        }

        var form = MultipartForm()
        form.addField("model_id", "scribe_v2")
        form.addField("tag_audio_events", "false")
        if !language.rawValue.isEmpty {
            form.addField("language_code", language.rawValue)
        }
        if includeKeyterms {
            for term in vocabulary {
                form.addField("keyterms", term)
            }
        }
        form.addFile("file", filename: "audio.wav", contentType: "audio/wav", data: audio)

        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.finalized()

        let data = try await send(request, provider: .elevenLabs)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            throw DictateError.badResponse(.elevenLabs)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func send(_ request: URLRequest, provider: TranscriptionProvider) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DictateError.badResponse(provider)
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DictateError.apiError(provider, status: http.statusCode, body: body)
        }
        return data
    }

    private static func joinWarnings(_ first: String?, _ second: String) -> String {
        guard let first else { return second }
        return first + " " + second
    }

    private static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "request timed out. Check the network or VPN."
            case .notConnectedToInternet, .networkConnectionLost:
                return "no internet connection."
            default:
                return urlError.localizedDescription
            }
        }
        return error.localizedDescription
    }

    private func correctText(_ text: String) async throws -> String {
        guard let apiKey = apiKeys[.groq] else {
            throw DictateError.noApiKey(.groq)
        }

        let termsStr = vocabulary.isEmpty ? "(none)" : vocabulary.joined(separator: ", ")
        let systemPrompt = """
            You are a transcription corrector for casual, conversational dictation. \
            The user dictates text via Whisper, mostly for Slack messages and Claude Code prompts — not formal writing or emails. \
            Your tasks:
            1. Correct obvious mis-hearings of words from this glossary: \(termsStr)
            2. Remove filler words (um, uh, like, so, you know, ähm, äh, halt, also, sozusagen).
            3. Keep the tone casual and conversational. Use minimal punctuation — only what's needed for clarity. Avoid unnecessary commas, semicolons, or formal sentence structures.
            4. Do not add formatting like bullet points, headings, or quote marks unless the user dictated them.
            5. Preserve 100% of the meaning and the user's voice — do not rephrase, polish, or invent content.
            6. Match the dictation language (German stays German, English stays English).
            Reply with ONLY the corrected text, no commentary.
            """

        let requestBody: [String: Any] = [
            // llama-3.3-70b-versatile was retired by Groq; qwen3.8-27b was the fastest
            // and most accurate replacement in a Nov 2026 benchmark.
            "model": "qwen/qwen3.8-27b",
            "reasoning_effort": "none",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text]
            ],
            "max_tokens": 500,
            "temperature": 0.2
        ]

        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let data = try await send(request, provider: .groq)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw DictateError.badResponse(.groq)
        }

        let corrected = content
            .replacingOccurrences(of: "(?s)<think>.*?</think>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return corrected.isEmpty ? text : corrected
    }

    // MARK: - Audio
    private func playStartSound() {
        SoundGenerator.shared.playStartSound()
    }

    private func playStopSound() {
        SoundGenerator.shared.playStopSound()
    }

    private func writeWAV(audioData: [Int16], to url: URL) throws {
        var header = WAVHeader(
            chunkSize: UInt32(36 + audioData.count * 2),
            subchunk2Size: UInt32(audioData.count * 2)
        )

        var data = Data()
        data.append(Data(bytes: &header, count: MemoryLayout<WAVHeader>.size))
        audioData.withUnsafeBufferPointer { buffer in
            data.append(buffer)
        }

        try data.write(to: url)
    }

    private func showNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                appLog.error("notification not delivered: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

// MARK: - Data Extension
private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }

    mutating func append<T>(_ buffer: UnsafeBufferPointer<T>) {
        append(contentsOf: UnsafeRawBufferPointer(buffer))
    }
}

struct MultipartForm {
    private let boundary = UUID().uuidString
    private var body = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func addField(_ name: String, _ value: String) {
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        body.append("\(value)\r\n")
    }

    mutating func addFile(_ name: String, filename: String, contentType: String, data: Data) {
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        body.append("Content-Type: \(contentType)\r\n\r\n")
        body.append(data)
        body.append("\r\n")
    }

    func finalized() -> Data {
        var result = body
        result.append("--\(boundary)--\r\n")
        return result
    }
}

// MARK: - Models
struct Config: Codable {
    var correct: Bool
    var language: String?
    var saveToClipboard: Bool
    var hotkey: String?
    var provider: String?

    enum CodingKeys: String, CodingKey {
        case correct
        case language
        case saveToClipboard = "save_to_clipboard"
        case hotkey
        case provider
    }

    init(correct: Bool, language: String?, saveToClipboard: Bool, hotkey: String?, provider: String?) {
        self.correct = correct
        self.language = language
        self.saveToClipboard = saveToClipboard
        self.hotkey = hotkey
        self.provider = provider
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        correct = try c.decodeIfPresent(Bool.self, forKey: .correct) ?? false
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? nil
        saveToClipboard = try c.decodeIfPresent(Bool.self, forKey: .saveToClipboard) ?? false
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? nil
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? nil
    }
}

struct Vocabulary: Codable {
    var terms: [String]
}

struct WAVHeader {
    var riff: (UInt8, UInt8, UInt8, UInt8) = (0x52, 0x49, 0x46, 0x46) // "RIFF"
    var chunkSize: UInt32
    var wave: (UInt8, UInt8, UInt8, UInt8) = (0x57, 0x41, 0x56, 0x45) // "WAVE"
    var fmt: (UInt8, UInt8, UInt8, UInt8) = (0x66, 0x6D, 0x74, 0x20)  // "fmt "
    var subchunk1Size: UInt32 = 16
    var audioFormat: UInt16 = 1      // PCM
    var numChannels: UInt16 = 1      // Mono
    var sampleRate: UInt32 = 16000
    var byteRate: UInt32 = 32000     // sampleRate * numChannels * bitsPerSample/8
    var blockAlign: UInt16 = 2       // numChannels * bitsPerSample/8
    var bitsPerSample: UInt16 = 16
    var data: (UInt8, UInt8, UInt8, UInt8) = (0x64, 0x61, 0x74, 0x61) // "data"
    var subchunk2Size: UInt32
}

enum DictateError: LocalizedError {
    case noApiKey(TranscriptionProvider)
    case apiError(TranscriptionProvider, status: Int, body: String)
    case badResponse(TranscriptionProvider)

    var errorDescription: String? {
        switch self {
        case .noApiKey(let provider):
            return "\(provider.shortName) API key not set"
        case .apiError(let provider, let status, let body):
            var message = "HTTP \(status): \(Self.extractMessage(from: body))"
            if provider == .groq && status == 403 {
                message += " (Groq blocks VPN/datacenter IPs; pause the VPN or switch to ElevenLabs)"
            }
            if status == 401 {
                message += " (check the \(provider.shortName) API key)"
            }
            return message
        case .badResponse(let provider):
            return "Unexpected response from \(provider.shortName)"
        }
    }

    /// Pulls the human-readable message out of Groq ({"error":{"message"}}) or
    /// ElevenLabs ({"detail":{"message"}} or {"detail":"..."}) error bodies.
    private static func extractMessage(from body: String) -> String {
        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
                return message
            }
            if let detail = json["detail"] as? [String: Any], let message = detail["message"] as? String {
                return message
            }
            if let detail = json["detail"] as? String {
                return detail
            }
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "no details" : String(trimmed.prefix(200))
    }
}

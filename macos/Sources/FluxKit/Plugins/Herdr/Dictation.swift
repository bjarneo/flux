@preconcurrency import AVFoundation
import Foundation
import Observation
import Speech

/// The languages of the speech recognizer. Each on-device check takes
/// about 70 ms, so the list of models on this Mac loads in the background.
@MainActor
@Observable
public final class SpeechLanguages {
    public static let shared = SpeechLanguages()

    /// The languages of the recognizer, as tags such as en-GB.
    public private(set) var supported: [String] = []
    /// The languages with a speech model on this Mac, or nil while they load.
    public private(set) var onDevice: [String]?
    @ObservationIgnored private var loading = false

    private init() {}

    /// Reads the languages again, for example when the language picker opens.
    public func load() {
        supported = Self.tags(SFSpeechRecognizer.supportedLocales())
        guard !loading else { return }
        loading = true
        let supported = supported
        Task.detached(priority: .utility) {
            let local = supported.filter { SFSpeechRecognizer(locale: Locale(identifier: $0))?.supportsOnDeviceRecognition == true }
            await MainActor.run {
                SpeechLanguages.shared.onDevice = local
                SpeechLanguages.shared.loading = false
            }
        }
    }

    /// True when `tag` has a speech model on this Mac. It checks at once
    /// when the list has not loaded yet.
    func isOnDevice(_ tag: String) -> Bool {
        if let onDevice { return onDevice.contains(tag) }
        return SFSpeechRecognizer(locale: Locale(identifier: tag))?.supportsOnDeviceRecognition == true
    }

    static func tags(_ locales: Set<Locale>) -> [String] {
        locales.map { $0.identifier.replacingOccurrences(of: "_", with: "-") }.sorted()
    }
}

/// Speech to text on this Mac, for the reply field of an agent. Flux uses
/// the on-device recognizer when this Mac has the speech model of the
/// language, and then the audio stays on the Mac. For other languages, the
/// recognizer sends the audio to Apple. The audio never goes to the
/// computer.
///
/// A recognition task can end during a long dictation, for example after a
/// long pause. `Dictation` then starts a new task on the same audio and
/// collects the text of each task, so a long prompt with pauses stays one
/// dictation. After a stop, it waits for the last text, so no words are
/// lost. The dictation ends when the user stops it, after `silenceStop`
/// with no speech, or after `maxTime`.
@MainActor
@Observable
public final class Dictation {
    public enum Phase: Sendable { case idle, listening, finishing }

    public private(set) var phase = Phase.idle
    /// The final text so far.
    public private(set) var settled = ""
    /// The words that the recognizer still hears. They can change.
    public private(set) var pending = ""
    /// The start of the dictation, in system uptime.
    public private(set) var startedAt: TimeInterval = 0
    /// True when the recognizer runs on this Mac.
    public private(set) var onDevice = false
    /// The message of the last failure. A new start clears it.
    public private(set) var error: String?
    /// The language of the dictation, as a tag such as en-GB.
    public private(set) var language = ""
    /// True when the last failure was about the language, so the user can choose another one.
    public private(set) var languageError = false
    /// The input level from 0 to 1. The wave reads it at each frame, so a
    /// change does not update the views.
    @ObservationIgnored public private(set) var level: Float = 0
    /// The last level report, in system uptime.
    @ObservationIgnored public private(set) var levelAt: TimeInterval = 0

    /// A dictation with no speech for this long ends by itself.
    public static let silenceStop: TimeInterval = 20
    /// The longest dictation.
    public static let maxTime: TimeInterval = 5 * 60
    /// The longest wait for the last text after a stop.
    private static let finishTimeout: Duration = .seconds(3)
    private static let watchInterval: Duration = .seconds(1)
    private static let retryDelay: Duration = .milliseconds(250)
    private static let maxRetries = 3

    /// Made at the first start, so that a view can hold a dictation cheaply.
    @ObservationIgnored private lazy var engine = AVAudioEngine()
    @ObservationIgnored private let feed = AudioFeed()
    @ObservationIgnored private var recognizer: SFSpeechRecognizer?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    /// The token of the running recognition task, or 0. Callbacks of older tasks do nothing.
    @ObservationIgnored private var session = 0
    @ObservationIgnored private var sessions = 0
    @ObservationIgnored private var hints: [String] = []
    @ObservationIgnored private var onDone: (@MainActor (String) -> Void)?
    /// The last time that the recognizer heard words, in system uptime.
    @ObservationIgnored private var spokeAt: TimeInterval = 0
    /// The last partial text of the running task.
    @ObservationIgnored private var lastPartial = ""
    /// The restarts after a failed task, since the last text.
    @ObservationIgnored private var retries = 0
    @ObservationIgnored private var audioOn = false
    @ObservationIgnored private var watch: Task<Void, Never>?
    @ObservationIgnored private var finishTimer: Task<Void, Never>?

    public init() {}

    /// True when this Mac has a speech recognizer for at least 1 language.
    public nonisolated static var available: Bool { !SFSpeechRecognizer.supportedLocales().isEmpty }

    /// Asks for Speech Recognition and the microphone. It returns a message
    /// for the user, or nil when Flux may use both.
    public nonisolated static func authorize() async -> String? {
        let speech: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard speech == .authorized else { return DictationText.speechDenied }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return nil
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio) ? nil : DictationText.micDenied
        default: return DictationText.micDenied
        }
    }

    /// Starts a dictation in the language `choice`, or in the Mac languages
    /// when it is empty. `hints` are words that the recognizer should
    /// expect, such as the project name. `onDone` gets the text at the end,
    /// unless the user cancels. It returns false when the dictation did not
    /// start, and `error` tells why. Call `authorize` first.
    @discardableResult
    public func start(language choice: String, hints: [String], onDone: @escaping @MainActor (String) -> Void) -> Bool {
        guard phase == .idle else { return false }
        error = nil
        languageError = false
        guard let tag = resolve(choice) else {
            languageError = true
            return false
        }
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: tag)), r.isAvailable else {
            error = "The speech recognizer for \(DictationText.languageName(tag)) is not available now. Try again."
            return false
        }
        r.queue = .main
        recognizer = r
        onDevice = r.supportsOnDeviceRecognition
        language = tag
        self.hints = hints
        self.onDone = onDone
        settled = ""
        pending = ""
        level = 0
        levelAt = 0
        retries = 0
        guard startAudio() else {
            error = DictationText.noMicrophone
            recognizer = nil
            return false
        }
        startedAt = Self.now()
        spokeAt = startedAt
        phase = .listening
        #if os(iOS)
        Self.running[ObjectIdentifier(self)] = WeakDictation(self)
        #endif
        listen()
        watch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.watchInterval)
                guard let self, self.phase == .listening else { return }
                if self.quiet() {
                    FluxLog.plugin.info("dictation: no speech for \(Int(Self.silenceStop)) s, stop")
                    self.stop()
                    return
                }
            }
        }
        return true
    }

    /// Stops the dictation. The recognizer finishes the last words, then
    /// the caller of `start` gets the text.
    public func stop() {
        guard phase == .listening else { return }
        phase = .finishing
        level = 0
        stopAudio()
        guard session != 0 else {
            finish()
            return
        }
        request?.endAudio()
        // A recognizer that sends no final text still ends the dictation with the text so far.
        finishTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.finishTimeout)
            guard !Task.isCancelled, let self, self.phase != .idle else { return }
            self.finish()
        }
    }

    /// Ends the dictation at once and keeps the text so far.
    public func stopNow() {
        guard phase != .idle else { return }
        finish()
    }

    /// Ends the dictation and drops its text.
    public func cancel() {
        guard phase != .idle else { return }
        onDone = nil
        finish()
    }

    #if os(iOS)
    /// The dictations that run.
    private static var running: [ObjectIdentifier: WeakDictation] = [:]

    /// Ends each dictation that runs and drops its text, for example when
    /// the app leaves the screen, so that no words go out later.
    public static func cancelAll() {
        for d in running.values.compactMap(\.value) { d.cancel() }
        running = [:]
    }
    #endif

    // MARK: Language

    /// The tag of the language to use, or nil with `error` set.
    private func resolve(_ choice: String) -> String? {
        let languages = SpeechLanguages.shared
        let supported = SpeechLanguages.tags(SFSpeechRecognizer.supportedLocales())
        if !choice.isEmpty {
            if supported.contains(choice) { return choice }
            error = DictationText.notSupported(choice)
            return nil
        }
        // The Mac languages in order. The first one with a model on this Mac
        // wins, else the first one that the recognizer supports at all.
        let preferred = DictationText.languages(Locale.preferredLanguages)
        let fallback = SFSpeechRecognizer().map { $0.locale.identifier.replacingOccurrences(of: "_", with: "-") }
        let local = languages.onDevice ?? preferred.compactMap { LanguageCatalog.match($0, in: supported, fallback: fallback) }.filter(languages.isOnDevice)
        if let tag = LanguageCatalog.automatic(preferred: preferred, available: local, fallback: fallback)
            ?? LanguageCatalog.automatic(preferred: preferred, available: supported, fallback: fallback) {
            return tag
        }
        error = DictationText.unsupported(preferred)
        return nil
    }

    // MARK: Audio

    /// Starts the microphone. It returns false when this Mac has no input.
    private func startAudio() -> Bool {
        #if os(iOS)
        // iOS gives the engine an input only while a recording session is active.
        do {
            try AudioSession.activate(.dictation)
        } catch {
            FluxLog.plugin.error("dictation: the audio session did not start: \(String(describing: error), privacy: .public)")
            return false
        }
        #endif
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            #if os(iOS)
            AudioSession.deactivate(.dictation)
            #endif
            return false
        }
        let feed = feed
        input.removeTap(onBus: 0)
        // The tap runs on the audio thread.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable [weak self] buffer, _ in
            feed.append(buffer)
            let db = Self.decibels(buffer)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.heard(db) } }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            FluxLog.plugin.error("dictation: the microphone did not start: \(String(describing: error), privacy: .public)")
            input.removeTap(onBus: 0)
            #if os(iOS)
            AudioSession.deactivate(.dictation)
            #endif
            return false
        }
        audioOn = true
        return true
    }

    private func stopAudio() {
        guard audioOn else { return }
        audioOn = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        #if os(iOS)
        AudioSession.deactivate(.dictation)
        #endif
    }

    private func heard(_ db: Float) {
        guard phase == .listening else { return }
        level = DictationText.level(decibels: db)
        levelAt = Self.now()
    }

    /// The RMS level of the first channel in dBFS.
    private nonisolated static func decibels(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return -160 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += data[0][i] * data[0][i] }
        let rms = (sum / Float(n)).squareRoot()
        return rms > 0 ? 20 * log10(rms) : -160
    }

    // MARK: Recognition

    /// Starts a recognition task on the running audio.
    private func listen() {
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        request.contextualStrings = hints
        // A language with a model on this Mac stays on this Mac.
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        sessions += 1
        let token = sessions
        session = token
        lastPartial = ""
        self.request = request
        feed.set(request)
        task = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            // The metadata comes with the end of an utterance.
            let utteranceEnd = result?.speechRecognitionMetadata != nil
            let e = error as NSError?
            let failure = e.map { Failure(domain: $0.domain, code: $0.code, description: $0.localizedDescription) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.received(token, text: text, final: final || utteranceEnd, ended: final, failure: failure) }
            }
        }
    }

    private struct Failure: Sendable {
        var domain: String
        var code: Int
        var description: String
    }

    private func received(_ token: Int, text: String?, final: Bool, ended: Bool, failure: Failure?) {
        guard token == session, phase != .idle else { return }
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            retries = 0
            if text != lastPartial { spokeAt = Self.now() }
            if final {
                commit(text)
            } else {
                // A text that starts again after a pause keeps the words before it.
                if DictationText.restarted(previous: lastPartial, next: text) { commit(lastPartial) }
                lastPartial = text
                pending = DictationText.unsettled(settled, text)
            }
        }
        if ended {
            taskEnded()
        } else if let failure {
            failed(failure)
        }
    }

    /// Adds a final text. Without one, the partial text counts.
    private func commit(_ text: String?) {
        let t = text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? pending
        settled = DictationText.merge(settled, t)
        pending = ""
        lastPartial = ""
    }

    /// The task ended with its final text. A new task starts while the user dictates.
    private func taskEnded() {
        clearTask()
        commit(nil)
        if phase == .finishing || quiet() {
            finish()
        } else {
            listen()
        }
    }

    private func failed(_ f: Failure) {
        clearTask()
        commit(nil)
        let silence = DictationText.isSilence(domain: f.domain, code: f.code)
        if phase == .finishing || quiet() {
            finish()
            return
        }
        guard silence || retries < Self.maxRetries else {
            FluxLog.plugin.error("dictation: \(f.domain, privacy: .public) \(f.code): \(f.description, privacy: .public)")
            error = DictationText.message(domain: f.domain, code: f.code, description: f.description)
            finish()
            return
        }
        if !silence { retries += 1 }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.retryDelay)
            guard let self, self.phase == .listening, self.session == 0 else { return }
            self.listen()
        }
    }

    private func clearTask() {
        session = 0
        task = nil
        request = nil
        feed.set(nil)
    }

    private func quiet() -> Bool {
        let now = Self.now()
        return now - spokeAt >= Self.silenceStop || now - startedAt >= Self.maxTime
    }

    /// Ends the dictation and gives the text to the caller of `start`.
    private func finish() {
        #if os(iOS)
        Self.running[ObjectIdentifier(self)] = nil
        #endif
        watch?.cancel()
        watch = nil
        finishTimer?.cancel()
        finishTimer = nil
        task?.cancel()
        clearTask()
        stopAudio()
        commit(nil)
        let text = settled
        let done = onDone
        onDone = nil
        recognizer = nil
        phase = .idle
        level = 0
        settled = ""
        pending = ""
        if !text.isEmpty { done?(text) }
    }

    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}

#if os(iOS)
/// A dictation that `Dictation.cancelAll` can reach, without keeping it.
@MainActor
private struct WeakDictation {
    weak var value: Dictation?

    init(_ value: Dictation) {
        self.value = value
    }
}
#endif

/// Carries the microphone buffers from the audio thread to the running
/// recognition request.
private final class AudioFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func set(_ r: SFSpeechAudioBufferRecognitionRequest?) { lock.withLock { request = r } }

    func append(_ buffer: AVAudioPCMBuffer) { lock.withLock { request }?.append(buffer) }
}

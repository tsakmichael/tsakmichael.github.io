//9fdd18ede7c5d708f462df2b4e5c17a0a8df775b

import Foundation
import SwiftUI
import AVFoundation
import Network
import CoreHaptics

// MARK: - Session logging

/// Rolling in-memory log of everything that happens during chapter-audio
/// preparation this session — endpoint attempts, failures, status messages.
/// Exists so a failure can be diagnosed on-device (via SessionLogView) when
/// Xcode's console isn't reachable, e.g. a slow device that won't stay
/// tethered. Not persisted to disk on purpose — this is a temporary,
/// per-session diagnostic aid, not a permanent log file.
actor SessionLogStore {
    static let shared = SessionLogStore()

    private var entries: [String] = []
    private let maxEntries = 500

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func log(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)"
        entries.append(line)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    func allLogs() -> String {
        entries.isEmpty ? "No logs yet this session." : entries.joined(separator: "\n")
    }

    func clear() {
        entries.removeAll()
    }
}

/// Prints as before AND appends to SessionLogStore, so nothing needs two
/// call sites. Safe to call from any context (fires the store write async).
@discardableResult
fileprivate func logSession(_ message: String) -> String {
    print(message)
    Task { await SessionLogStore.shared.log(message) }
    return message
}

enum PlaybackTimingMode: String, CaseIterable, Identifiable {
    case timedText
    case remoteAudio

    var id: String { rawValue }
}

struct VerseTimingCue: Codable, Hashable {
    let verse: Int
    let startTime: Double
    let endTime: Double?
}

struct ChapterAudioPackage: Hashable {
    let localAudioURL: URL
    let cues: [VerseTimingCue]
    let bookNumber: Int
    let chapterNumber: Int
    let version: String
}

// MARK: - Voice selection

/// Canonical, UI-facing voice choice. Each endpoint knows how to translate
/// this into whatever string format its own API expects.
enum ChapterVoiceSelection: String, CaseIterable, Codable {
    case anna
    case jenny
    case aria
    case sonia
    case eric

    static func from(userDefaultsValue: String?) -> ChapterVoiceSelection {
        switch userDefaultsValue {
        case "Jenny": return .jenny
        case "Aria": return .aria
        case "Sonia": return .sonia
        case "Eric": return .eric
        default: return .aria
        }
    }

    /// Azure-style identifier, used by servers that speak the Azure Speech
    /// voice naming convention (mirror-api, local dev server).
    var azureIdentifier: String {
        switch self {
        case .anna: return "en-US-AriaNeural"
        case .jenny: return "en-US-JennyNeural"
        case .aria: return "en-US-AriaNeural"
        case .sonia: return "en-GB-SoniaNeural"
        case .eric: return "en-US-EricNeural"
        }
    }

    /// mike-tts appears to be a Piper server, which only supports three
    /// voices: kathleen, lessac (spelling unconfirmed — verify against the
    /// server), and joe. None of the UI voice choices map 1:1 to those, so
    /// everything falls back to kathleen, the preferred default, except
    /// where an explicit mapping makes sense.
    var mikeVoiceName: String {
        switch self {
        case .anna: return "kathleen"
        case .jenny: return "kathleen"
        case .aria: return "kathleen"
        case .sonia: return "lessac"
        case .eric: return "joe"
        }
    }
}

fileprivate struct VersePlaybackContext {
    let verseTexts: [String]
    let startingVerse: Int
    let chapterAudioPackage: ChapterAudioPackage?
    let playbackSpeed: Int
    let playbackVolume: Float
}

fileprivate protocol VersePlaybackBackend: AnyObject {
    var mode: PlaybackTimingMode { get }
    func start(
        context: VersePlaybackContext,
        onAdvance: @escaping (Int) -> Void,
        onTimeUpdate: @escaping (Double?) -> Void,
        onFinish: @escaping () -> Void
    )
    func stop()
    func pause()
    func resume()
    func seek(to verse: Int)
    func setVolume(_ volume: Float)
}


fileprivate final class TimedVersePlaybackBackend: VersePlaybackBackend {
    let mode: PlaybackTimingMode = .timedText

    private var context: VersePlaybackContext?
    private var onAdvance: ((Int) -> Void)?
    private var onFinish: (() -> Void)?
    private var workItem: DispatchWorkItem?
    private var currentVerse: Int = 1

    func start(
        context: VersePlaybackContext,
        onAdvance: @escaping (Int) -> Void,
        onTimeUpdate: @escaping (Double?) -> Void,
        onFinish: @escaping () -> Void
    ) {
        stop()
        self.context = context
        self.onAdvance = onAdvance
        self.onFinish = onFinish
        currentVerse = max(1, min(context.startingVerse, context.verseTexts.count))
        onTimeUpdate(nil)
        onAdvance(currentVerse)
        scheduleNextAdvance()
    }

    func stop() {
        workItem?.cancel()
        workItem = nil
    }

    func pause() {
        workItem?.cancel()
        workItem = nil
    }

    func resume() {
        scheduleNextAdvance()
    }

    func seek(to verse: Int) {
        guard let context else { return }
        currentVerse = max(1, min(verse, context.verseTexts.count))
        onAdvance?(currentVerse)
        scheduleNextAdvance()
    }

    func setVolume(_ volume: Float) {}

    private func scheduleNextAdvance() {
        guard let context else { return }
        workItem?.cancel()

        guard currentVerse < context.verseTexts.count else {
            onFinish?()
            return
        }

        let currentText = context.verseTexts[currentVerse - 1]
        let delay = estimatedDuration(for: currentText, speed: context.playbackSpeed)
        let nextVerse = currentVerse + 1

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.currentVerse = nextVerse
            self.onAdvance?(nextVerse)
            self.scheduleNextAdvance()
        }

        workItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func estimatedDuration(for verseText: String, speed: Int) -> TimeInterval {
        let wordCount = max(verseText.split(whereSeparator: \.isWhitespace).count, 1)
        let base = max(1.5, Double(wordCount) * 0.32)
        let clampedSpeed = min(max(speed, 1), 9)
        let factor = 0.7 + (Double(clampedSpeed - 1) * 0.11)
        return max(0.8, base / factor)
    }
}


fileprivate final class RemoteTimedAudioPlaybackBackend: NSObject, VersePlaybackBackend {
    let mode: PlaybackTimingMode = .remoteAudio

    private let fallback = TimedVersePlaybackBackend()
    private let player = AVPlayer()
    private var timeObserverToken: Any?
    private var endObserver: NSObjectProtocol?
    private var context: VersePlaybackContext?
    private var onAdvance: ((Int) -> Void)?
    private var onTimeUpdate: ((Double?) -> Void)?
    private var onFinish: (() -> Void)?
    private var currentVerse: Int = 1
    private var cues: [VerseTimingCue] = []
    private var usingTimedAudio = false

    func start(
        context: VersePlaybackContext,
        onAdvance: @escaping (Int) -> Void,
        onTimeUpdate: @escaping (Double?) -> Void,
        onFinish: @escaping () -> Void
    ) {
        stop()
        self.context = context
        self.onAdvance = onAdvance
        self.onFinish = onFinish
        self.onTimeUpdate = onTimeUpdate
        currentVerse = max(1, min(context.startingVerse, context.verseTexts.count))

        if let package = context.chapterAudioPackage, !package.cues.isEmpty {
            attachChapterAudioPackage(package, currentVerse: currentVerse)
        } else {
            usingTimedAudio = false
            onTimeUpdate(nil)
            fallback.start(context: context, onAdvance: onAdvance, onTimeUpdate: onTimeUpdate, onFinish: onFinish)
        }
    }

    func stop() {
        fallback.stop()
        player.pause()
        player.replaceCurrentItem(with: nil)
        removeObservers()
        context = nil
        onAdvance = nil
        onTimeUpdate = nil
        onFinish = nil
        cues = []
        usingTimedAudio = false
    }

    func pause() {
        if usingTimedAudio {
            player.pause()
        } else {
            fallback.pause()
        }
    }

    func resume() {
        if usingTimedAudio {
            let speed = context?.playbackSpeed ?? 5
            player.play()
            player.rate = playerRate(for: speed)
        } else {
            fallback.resume()
        }
    }

    private func playerRate(for speed: Int) -> Float {
        let clampedSpeed = min(max(speed, 1), 9)
        let rates: [Float] = [0.6, 0.7, 0.8, 0.9, 1.0, 1.15, 1.3, 1.6, 2.0]
        return rates[clampedSpeed - 1]
    }

    func seek(to verse: Int) {
        guard let context else { return }
        currentVerse = max(1, min(verse, context.verseTexts.count))

        if usingTimedAudio {
            onAdvance?(currentVerse)
            seekPlayer(to: currentVerse, shouldResume: true)
        } else {
            fallback.seek(to: currentVerse)
        }
    }

    func setVolume(_ volume: Float) {
        let clampedVolume = min(max(volume, 0), 1)
        player.volume = clampedVolume
        fallback.setVolume(clampedVolume)

        guard let context else { return }
        self.context = VersePlaybackContext(
            verseTexts: context.verseTexts,
            startingVerse: context.startingVerse,
            chapterAudioPackage: context.chapterAudioPackage,
            playbackSpeed: context.playbackSpeed,
            playbackVolume: clampedVolume
        )
    }

    fileprivate func attachChapterAudioPackage(_ package: ChapterAudioPackage, currentVerse: Int) {
        guard let context else { return }

        let normalizedCues = package.cues.sorted { $0.startTime < $1.startTime }
        guard !normalizedCues.isEmpty else { return }

        cues = normalizedCues
        usingTimedAudio = true
        fallback.stop()
        self.currentVerse = max(1, min(currentVerse, context.verseTexts.count))
        configureAudioSession()
        configurePlayer(with: package.localAudioURL)
        onAdvance?(self.currentVerse)
        seekPlayer(to: self.currentVerse, shouldResume: true)
    }

    private func configurePlayer(with url: URL) {
        removeObservers()

        let item = AVPlayerItem(url: url)
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.onFinish?()
        }

        let interval = CMTime(seconds: 0.15, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.handlePlaybackTimeChange(time)
        }

        player.replaceCurrentItem(with: item)
        player.volume = context?.playbackVolume ?? 1.0
    }

    private func seekPlayer(to verse: Int, shouldResume: Bool) {
        let targetSeconds = cueStartTime(for: verse) ?? cues.first?.startTime ?? 0
        let targetTime = CMTime(seconds: targetSeconds, preferredTimescale: 600)
        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self = self, shouldResume else { return }
            let speed = self.context?.playbackSpeed ?? 5
            self.player.play()
            self.player.rate = self.playerRate(for: speed)
        }
    }

    private func handlePlaybackTimeChange(_ time: CMTime) {
        guard usingTimedAudio else { return }

        let seconds = time.seconds
        guard seconds.isFinite, let verse = verse(for: seconds) else { return }

        let duration = player.currentItem?.duration.seconds ?? 0
        if duration > 0 && duration.isFinite {
            onTimeUpdate?(max(0, duration - seconds))
        } else {
            onTimeUpdate?(nil)
        }

        if verse != currentVerse {
            currentVerse = verse
            onAdvance?(verse)
        }
    }

    private func verse(for seconds: Double) -> Int? {
        guard let currentIndex = cues.lastIndex(where: { cue in
            let cueEnd = cue.endTime ?? Double.greatestFiniteMagnitude
            return seconds >= cue.startTime && seconds < cueEnd
        }) else {
            return cues.last(where: { seconds >= $0.startTime })?.verse
        }

        return cues[currentIndex].verse
    }

    private func cueStartTime(for verse: Int) -> Double? {
        if let match = cues.first(where: { $0.verse == verse }) {
            return match.startTime
        }

        return cues.last(where: { $0.verse <= verse })?.startTime
    }

    private func removeObservers() {
        if let timeObserverToken {
            player.removeTimeObserver(timeObserverToken)
            self.timeObserverToken = nil
        }

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Timed audio session configuration failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Chapter descriptor

 struct ChapterAudioDescriptor: Hashable {
    let voice: ChapterVoiceSelection
    let bookNumber: Int
    let chapterNumber: Int
    let bookTitle: String
    let version: String

    var chapterReference: String {
        "\(bookTitle) \(chapterNumber + 1)"
    }

    /// Cache key is per book/chapter/version/voice, independent of which
    /// server ends up serving the audio (different servers may legitimately
    /// produce different audio for the same cache key — that's fine, the
    /// cache just tracks "the audio we currently have for this chapter+voice").
    var cacheKey: String {
        "\(version.lowercased())-\(bookNumber)-\(chapterNumber)-\(voice.rawValue)"
    }
}

fileprivate struct ChapterAudioCacheEntry: Codable {
    let cacheKey: String
    let audioRelativePath: String
    let cues: [VerseTimingCue]
    var lastAccessedAt: Date
}

// MARK: - Endpoint adapters

/// Result of hitting an endpoint. `.pending` is for job-style APIs that
/// return a statusUrl to poll; endpoints that answer synchronously just
/// always return `.ready`.
enum ChapterAudioParseResult {
    case ready(audioURLString: String, cues: [VerseTimingCue])
    case pending(statusURL: URL)
}

/// One adapter per server. Each adapter owns its own request shape AND its
/// own response shape, so servers with different contracts can live side by
/// side without the shared retry/caching/polling logic in ChapterAudioService
/// needing to know or care about those differences.
protocol ChapterAudioEndpoint {
    var url: URL { get }
    var displayName: String { get }

    func makeRequest(descriptor: ChapterAudioDescriptor, verses: [String]) throws -> URLRequest

    /// Parse the response from the initial POST. `async` because some
    /// servers (mirror-api) only return a *pointer* to the timings JSON in
    /// the initial response — resolving to `.ready` requires a second fetch.
    func parseInitialResponse(data: Data, httpResponse: HTTPURLResponse, session: URLSession) async throws -> ChapterAudioParseResult

    /// Parse a response from polling a statusURL returned by `.pending`.
    /// Default implementation just re-uses parseInitialResponse, which is
    /// correct for any endpoint that never returns `.pending`.
    func parseStatusResponse(data: Data, httpResponse: HTTPURLResponse, session: URLSession) async throws -> ChapterAudioParseResult
}

extension ChapterAudioEndpoint {
    func parseStatusResponse(data: Data, httpResponse: HTTPURLResponse, session: URLSession) async throws -> ChapterAudioParseResult {
        try await parseInitialResponse(data: data, httpResponse: httpResponse, session: session)
    }
}

/// Accepts either a JSON number or a JSON string for "verse" — mirror-api's
/// server code stores whatever type the request sent it (string or int)
/// straight through into the timings JSON, so this has to tolerate both.
fileprivate struct IntOrString: Decodable {
    let intValue: Int?
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(Int.self) {
            intValue = intVal
        } else if let strVal = try? container.decode(String.self) {
            intValue = Int(strVal)
        } else {
            intValue = nil
        }
    }
}

/// Shared parser for the mirror-api FastAPI server shape (also used by the
/// local dev server, since it's the same codebase run locally). The real
/// `/api/audio` response looks like:
///
///   { "audioUrl": "...", "url": "...", "timingsAvailable": true,
///     "timings": { "allUrl": "https://firebasestorage.../all-timings.json" },
///     "counts": { "words": N, "sentences": N, "verses": N } }
///
/// Note there are NO inline timing arrays here — `timings.allUrl` points at
/// a separate Firebase-hosted JSON blob shaped like:
///
///   { "wordTimings": [...], "sentenceTimings": [...],
///     "verseTimings": [ { "verse": 1, "text": "...", "start": 0.12,
///                          "duration": 1.4, "end": 1.52 }, ... ] }
///
/// This deliberately reads `verseTimings` only, not `sentenceTimings` —
/// the server's sentence splitting is regex-based on `.!?` and has no
/// relationship to verse boundaries, so a sentence can span multiple verses
/// or a verse can contain multiple sentences. `VerseTimingCue` has no
/// separate "this is sentence-granularity" concept, so treating sentence
/// spans as verse cues would silently mislabel playback. verseTimings are
/// only present when the request included a `verses` array (which every
/// adapter here does), and only populated at all now that the server
/// requests WordBoundary events — see the fix note in mirror_api.py.
fileprivate func parseMirrorStyleResponse(
    data: Data,
    session: URLSession
) async throws -> ChapterAudioParseResult {
    struct InitialResponse: Decodable {
        struct TimingsLink: Decodable {
            let allUrl: String?
        }
        let audioUrl: String?
        let url: String?
        let timingsAvailable: Bool?
        let timings: TimingsLink?
    }

    let initial = try JSONDecoder().decode(InitialResponse.self, from: data)

    guard let audioURLString = initial.audioUrl ?? initial.url else {
        throw NSError(
            domain: "ChapterAudioEndpoint",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Response missing audioUrl."]
        )
    }

    // Server now reports this explicitly (see timingsAvailable in the fixed
    // mirror_api.py) — trust it rather than discovering emptiness after a
    // second network round trip.
    if initial.timingsAvailable == false {
        throw NSError(
            domain: "ChapterAudioEndpoint",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Server reported timingsAvailable: false — audio generated but no word/verse timing data."]
        )
    }

    guard let allURLString = initial.timings?.allUrl, let allURL = URL(string: allURLString) else {
        throw NSError(
            domain: "ChapterAudioEndpoint",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Response missing timings.allUrl."]
        )
    }

    let (timingsData, timingsResponse) = try await session.data(from: allURL)
    guard let httpTimingsResponse = timingsResponse as? HTTPURLResponse,
          (200...299).contains(httpTimingsResponse.statusCode) else {
        let statusCode = (timingsResponse as? HTTPURLResponse)?.statusCode ?? -1
        let bodySnippet = String(data: timingsData.prefix(300), encoding: .utf8) ?? "<non-utf8 body>"
        // Common cause: the URL your server generated has no Firebase Storage
        // download token (the ?alt=media query alone isn't enough unless the
        // object/bucket is public) — a 403 here with an HTML/JSON error body
        // naming permissions is the tell. Log it explicitly rather than
        // guessing next time.
        throw NSError(
            domain: "ChapterAudioEndpoint",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "Failed to fetch timings.allUrl (status \(statusCode)): \(bodySnippet)"]
        )
    }

    struct AllTimingsResponse: Decodable {
        struct VerseTimingEntry: Decodable {
            let verse: IntOrString?
            let start: Double?
            let end: Double?

            /// build_span_timings emits a "null start/end" entry for
            /// zero-token verse text instead of omitting it — skip those
            /// rather than producing a bogus zero-second cue.
            var cue: VerseTimingCue? {
                guard let verseNumber = verse?.intValue, let start else { return nil }
                return VerseTimingCue(verse: verseNumber, startTime: start, endTime: end)
            }
        }
        let verseTimings: [VerseTimingEntry]?
    }

    let allTimings: AllTimingsResponse
    do {
        allTimings = try JSONDecoder().decode(AllTimingsResponse.self, from: timingsData)
    } catch {
        let bodySnippet = String(data: timingsData.prefix(300), encoding: .utf8) ?? "<non-utf8 body>"
        throw NSError(
            domain: "ChapterAudioEndpoint",
            code: 6,
            userInfo: [NSLocalizedDescriptionKey: "timings.allUrl returned 200 but body didn't decode as expected: \(bodySnippet)"]
        )
    }
    let cues = (allTimings.verseTimings ?? []).compactMap(\.cue)

    guard !cues.isEmpty else {
        throw NSError(
            domain: "ChapterAudioEndpoint",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "timings.allUrl fetched but verseTimings was empty."]
        )
    }

    return .ready(audioURLString: audioURLString, cues: cues)
}

/// https://mirror-api-991075429415.us-central1.run.app/api/audio
/// Request: { text, voice, variant, verses: [{ verse: "1", text }] }  — verse is a STRING.
struct MirrorAPIEndpoint: ChapterAudioEndpoint {
    let url = URL(string: "https://mirror-api-991075429415.us-central1.run.app/api/audio")!
    let displayName = "mirror-api"

    func makeRequest(descriptor: ChapterAudioDescriptor, verses: [String]) throws -> URLRequest {
        let combinedText = "\(descriptor.chapterReference).\n" + verses.joined(separator: "\n")
        let body: [String: Any] = [
            "text": combinedText,
            "voice": descriptor.voice.azureIdentifier,
            "variant": "original",
            "version": descriptor.version,
            "book": descriptor.bookTitle,
            "bookNumber": descriptor.bookNumber,
            "chapter": descriptor.chapterNumber,
            "verses": verses.enumerated().map { index, text in
                ["verse": String(index + 1), "text": text]
            }
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func parseInitialResponse(data: Data, httpResponse: HTTPURLResponse, session: URLSession) async throws -> ChapterAudioParseResult {
        try await parseMirrorStyleResponse(data: data, session: session)
    }
}

/// http://localhost:3000/api/audio (override via UserDefaults "chapterAudioServiceURL",
/// e.g. to point at http://10.0.0.40:3000/api/audio on a device on your LAN)
/// Request: { text, voice, variant, verses: [{ verse: 1, text }] }  — verse is an INT.
/// AudioVixServer returns generated verse timings inline, so this adapter
/// deliberately does not use MirrorAPIEndpoint's timings.allUrl contract.
struct LocalDevEndpoint: ChapterAudioEndpoint {
    let url: URL
    let displayName = "local-dev"

    init(url: URL = URL(string: "http://localhost:3000/api/audio")!) {
        self.url = url
    }

    func makeRequest(descriptor: ChapterAudioDescriptor, verses: [String]) throws -> URLRequest {
        let combinedText = "\(descriptor.chapterReference).\n" + verses.joined(separator: "\n")
        let body: [String: Any] = [
            "text": combinedText,
            "voice": descriptor.voice.azureIdentifier,
            "variant": "original",
            "version": descriptor.version,
            "book": descriptor.bookTitle,
            "bookNumber": descriptor.bookNumber,
            "chapter": descriptor.chapterNumber,
            "verses": verses.enumerated().map { index, text in
                ["verse": String(index + 1), "text": text]
            }
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func parseInitialResponse(data: Data, httpResponse: HTTPURLResponse, session: URLSession) async throws -> ChapterAudioParseResult {
        struct LocalResponse: Decodable {
            struct Timings: Decodable {
                struct VerseTiming: Decodable {
                    let verse: IntOrString?
                    let start: Double?
                    let end: Double?
                }
                let verseTimings: [VerseTiming]?
            }
            let audioUrl: String?
            let url: String?
            let timings: Timings?
        }
        
        let response = try JSONDecoder().decode(LocalResponse.self, from: data)
        guard let audioURLString = response.audioUrl ?? response.url else {
            throw NSError(
                domain: "LocalDevEndpoint",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Response missing audioUrl."]
            )
        }
        
        let cues = (response.timings?.verseTimings ?? []).compactMap { timing -> VerseTimingCue? in
            guard let verse = timing.verse?.intValue, let start = timing.start else { return nil }
            return VerseTimingCue(verse: verse, startTime: start, endTime: timing.end)
        }
        guard !cues.isEmpty else {
            throw NSError(
                domain: "LocalDevEndpoint",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Response missing inline verse timings."]
            )
        }
        
        return .ready(audioURLString: audioURLString, cues: cues)
    }
}

/// https://mike-tts.fly.dev/api/audio
/// Request: { text, version, book, bookNumber, chapter, voice, reference, verses: ["...", "..."] }
///   — verses is a flat array of strings (no verse numbers), and cue numbering
///   has to be inferred from array order on the response side.
/// Response shape unconfirmed — this reuses the { audioUrl, timings: { verseTimings: [...] } }
/// shape from the original TtsService.synthesize. Verify against a live response.
struct MikeTTSEndpoint: ChapterAudioEndpoint {
    let url = URL(string: "https://mike-tts.fly.dev/api/audio")!
    let displayName = "mike-tts"

    func makeRequest(descriptor: ChapterAudioDescriptor, verses: [String]) throws -> URLRequest {
        let combinedText = verses.joined(separator: "\n")
        let body: [String: Any] = [
            "text": combinedText,
            "version": descriptor.version,
            "book": descriptor.bookTitle,
            "bookNumber": descriptor.bookNumber,
            "chapter": descriptor.chapterNumber,
            "voice": descriptor.voice.mikeVoiceName,
            "reference": descriptor.chapterReference,
            "verses": verses
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func parseInitialResponse(data: Data, httpResponse: HTTPURLResponse, session: URLSession) async throws -> ChapterAudioParseResult {
        let json: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "MikeTTSEndpoint", code: 3, userInfo: nil)
            }
            json = decoded
        } catch {
            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "<none>"
            let bodySnippet = String(data: data.prefix(300), encoding: .utf8) ?? "<non-utf8 body>"
            // This was showing up as a bare "isn't in the correct format"
            // error with no way to tell what mike-tts actually sent back —
            // now the log will have the real content-type and a body
            // snippet, which is enough to tell an HTML error page apart
            // from a differently-shaped JSON response.
            throw NSError(
                domain: "MikeTTSEndpoint",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Response (status \(httpResponse.statusCode), content-type \(contentType)) wasn't the expected JSON shape: \(bodySnippet)"]
            )
        }

        guard let audioURLString = json["audioUrl"] as? String else {
            throw NSError(
                domain: "MikeTTSEndpoint",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Response missing audioUrl. Keys present: \(json.keys.sorted())"]
            )
        }

        let rawTimings = (json["timings"] as? [String: Any])?["verseTimings"] as? [[String: Any]] ?? []
        let cues: [VerseTimingCue] = rawTimings.compactMap { item in
            guard let verse = item["verse"] as? Int else { return nil }
            let start = item["start"] as? Double ?? item["startTime"] as? Double
            let end = item["end"] as? Double ?? item["endTime"] as? Double
            guard let start else { return nil }
            return VerseTimingCue(verse: verse, startTime: start, endTime: end)
        }

        guard !cues.isEmpty else {
            throw NSError(
                domain: "MikeTTSEndpoint",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Response missing verse timings."]
            )
        }

        return .ready(audioURLString: audioURLString, cues: cues)
    }
}

// MARK: - Chapter audio service

actor ChapterAudioService {
    static let shared = ChapterAudioService()

    private let fileManager = FileManager.default
    private let cacheLimit = 10
    private let cacheFolderName = "TimedChapterAudioCache"
    private let metadataFilename = "timed-chapter-audio-cache-index.json"
    private let requestTimeout: TimeInterval = 180

    private let session: URLSession
    private let cacheDirectoryURL: URL
    private let metadataURL: URL

    private var metadata: [String: ChapterAudioCacheEntry] = [:]
    private var inFlightTasks: [String: Task<ChapterAudioPackage?, Never>] = [:]

    private var hapticEngine: CHHapticEngine?
    private var statusCallback: ((String) -> Void)?

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        session = URLSession(configuration: configuration)

        let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        cacheDirectoryURL = cachesDirectory.appendingPathComponent(cacheFolderName, isDirectory: true)
        metadataURL = cacheDirectoryURL.appendingPathComponent(metadataFilename, isDirectory: false)

        do {
            try fileManager.createDirectory(at: cacheDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        } catch {
            print("Failed to create timed audio cache directory: \(error.localizedDescription)")
        }

        loadMetadata()
        purgeMissingFiles()
        setupHaptics()
    }

    func setStatusCallback(_ callback: @escaping (String) -> Void) {
        statusCallback = callback
    }

    private func setupHaptics() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }

        do {
            hapticEngine = try CHHapticEngine()
            try hapticEngine?.start()
        } catch {
            print("Haptic engine setup failed: \(error.localizedDescription)")
        }
    }

    private func triggerHaptic(_ pattern: CHHapticPattern) {
        guard let engine = hapticEngine else { return }
        do {
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: 0)
        } catch {
            print("Haptic playback failed: \(error.localizedDescription)")
        }
    }

    private func playEndpointSwitchHaptic() {
        let event = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.7),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
            ],
            relativeTime: 0
        )

        do {
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            triggerHaptic(pattern)
        } catch {
            print("Haptic pattern creation failed: \(error.localizedDescription)")
        }
    }

    private func playSuccessHaptic() {
        let event = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3)
            ],
            relativeTime: 0
        )

        do {
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            triggerHaptic(pattern)
        } catch {
            print("Haptic pattern creation failed: \(error.localizedDescription)")
        }
    }

    private func playFailureHaptic() {
        let event1 = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.8),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.8)
            ],
            relativeTime: 0
        )

        let event2 = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.6),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.6)
            ],
            relativeTime: 0.1
        )

        do {
            let pattern = try CHHapticPattern(events: [event1, event2], parameters: [])
            triggerHaptic(pattern)
        } catch {
            print("Haptic pattern creation failed: \(error.localizedDescription)")
        }
    }

    nonisolated private func updateStatus(_ message: String) {
        Task { await SessionLogStore.shared.log(message) }
        Task { @MainActor [weak self] in
            await self?.statusCallback?(message)
        }
    }

    fileprivate func cachedChapterAudioPackage(for descriptor: ChapterAudioDescriptor) -> ChapterAudioPackage? {
        guard let entry = metadata[descriptor.cacheKey] else { return nil }
        let fileURL = cacheDirectoryURL.appendingPathComponent(entry.audioRelativePath, isDirectory: false)

        var isDirectory: ObjCBool = false
        let isValidFile = fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue

        guard isValidFile, !entry.cues.isEmpty else {
            metadata.removeValue(forKey: descriptor.cacheKey)
            persistMetadata()
            return nil
        }

        touch(descriptor.cacheKey)
        return ChapterAudioPackage(
            localAudioURL: fileURL,
            cues: entry.cues.sorted { $0.verse < $1.verse },
            bookNumber: descriptor.bookNumber,
            chapterNumber: descriptor.chapterNumber,
            version: descriptor.version
        )
    }

    fileprivate func prepareChapterAudioPackage(
        for descriptor: ChapterAudioDescriptor,
        verses: [String],
        endpoints: [ChapterAudioEndpoint]
    ) async -> ChapterAudioPackage? {
        if let cached = cachedChapterAudioPackage(for: descriptor) {
            return cached
        }

        if let task = inFlightTasks[descriptor.cacheKey] {
            return await task.value
        }

        guard !endpoints.isEmpty else { return nil }

        let task = Task<ChapterAudioPackage?, Never> {
            let endpointCount = endpoints.count

            for (index, endpoint) in endpoints.enumerated() {
                let isLastEndpoint = index == endpointCount - 1

                updateStatus("Trying audio endpoint \(index + 1)/\(endpointCount): \(endpoint.displayName)...")

                do {
                    let result = try await self.fetchAndCacheChapterAudioPackage(
                        for: descriptor,
                        verses: verses,
                        endpoint: endpoint
                    )

                    playSuccessHaptic()
                    updateStatus("Audio loaded successfully from \(endpoint.displayName)")
                    return result
                } catch {
                    logSession("Timed audio request failed for \(descriptor.chapterReference) via \(endpoint.displayName): \(error.localizedDescription)")

                    if isLastEndpoint {
                        playFailureHaptic()
                        updateStatus("All audio endpoints failed")
                    } else {
                        playEndpointSwitchHaptic()
                        updateStatus("Endpoint \(endpoint.displayName) failed. Trying next endpoint...")
                    }
                }
            }

            return nil
        }

        inFlightTasks[descriptor.cacheKey] = task
        let result = await task.value
        inFlightTasks.removeValue(forKey: descriptor.cacheKey)
        return result
    }

    func cancelAllRequests(except keepKeys: Set<String> = []) {
        for (key, task) in inFlightTasks where !keepKeys.contains(key) {
            task.cancel()
        }
        inFlightTasks = inFlightTasks.filter { keepKeys.contains($0.key) }
    }

    private func fetchAndCacheChapterAudioPackage(
        for descriptor: ChapterAudioDescriptor,
        verses: [String],
        endpoint: ChapterAudioEndpoint
    ) async throws -> ChapterAudioPackage {
        let cleanedVerses = verses.map { cleanSubscriptsAndSuperscripts($0) }
        let request = try endpoint.makeRequest(descriptor: descriptor, verses: cleanedVerses)

        let (responseData, response) = try await session.data(for: request)
        try Task.checkCancellation()
        let httpResponse = try validatedHTTPResponse(from: response, data: responseData)

        var result = try await endpoint.parseInitialResponse(data: responseData, httpResponse: httpResponse, session: session)
        result = try await resolvePending(result, endpoint: endpoint)

        guard case let .ready(audioURLString, cues) = result else {
            throw NSError(
                domain: "ChapterAudioService",
                code: 1002,
                userInfo: [NSLocalizedDescriptionKey: "\(endpoint.displayName) never resolved to a ready audio URL."]
            )
        }

        let audioRemoteURL = try url(from: audioURLString)
        let (audioData, audioResponse) = try await session.data(from: audioRemoteURL)
        _ = try validatedHTTPResponse(from: audioResponse, data: audioData)

        let chapterFolderName = safeFilename(from: descriptor.cacheKey)
        let chapterFolder = cacheDirectoryURL.appendingPathComponent(chapterFolderName, isDirectory: true)

        var chapterFolderIsDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: chapterFolder.path, isDirectory: &chapterFolderIsDirectory),
           !chapterFolderIsDirectory.boolValue {
            try fileManager.removeItem(at: chapterFolder)
        }
        try fileManager.createDirectory(at: chapterFolder, withIntermediateDirectories: true, attributes: nil)

        // Keep the local cache name independent of the Firebase object name.
        // The remote URL may contain a hash filename or query-specific path
        // components, and stale installs can already contain that name as a directory.
        let audioFilename = "chapter.mp3"
        let fileURL = chapterFolder.appendingPathComponent(audioFilename, isDirectory: false)
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
        try audioData.write(to: fileURL, options: .atomic)

        logSession("Cached timed audio at \(fileURL.path); bytes=\(audioData.count); cues=\(cues.count)")

        let relativePath = chapterFolderName + "/" + audioFilename
        let entry = ChapterAudioCacheEntry(
            cacheKey: descriptor.cacheKey,
            audioRelativePath: relativePath,
            cues: cues,
            lastAccessedAt: Date()
        )

        metadata[descriptor.cacheKey] = entry
        pruneCacheIfNeeded()
        persistMetadata()

        return ChapterAudioPackage(
            localAudioURL: fileURL,
            cues: cues,
            bookNumber: descriptor.bookNumber,
            chapterNumber: descriptor.chapterNumber,
            version: descriptor.version
        )
    }

    /// Polls a `.pending` result via the endpoint's own status parser until
    /// it resolves to `.ready`, times out, or fails.
    private func resolvePending(
        _ initial: ChapterAudioParseResult,
        endpoint: ChapterAudioEndpoint
    ) async throws -> ChapterAudioParseResult {
        var current = initial
        let maxAttempts = 60

        for attempt in 0..<maxAttempts {
            guard case let .pending(statusURL) = current else { return current }
            try Task.checkCancellation()

            if attempt > 0 {
                try await Task.sleep(nanoseconds: 1_500_000_000)
            }

            let (statusData, statusResponse) = try await session.data(from: statusURL)
            let httpResponse = try validatedHTTPResponse(from: statusResponse, data: statusData)
            current = try await endpoint.parseStatusResponse(data: statusData, httpResponse: httpResponse, session: session)
        }

        throw NSError(
            domain: "ChapterAudioService",
            code: 1003,
            userInfo: [NSLocalizedDescriptionKey: "\(endpoint.displayName) timed audio generation timed out."]
        )
    }

    private func validatedHTTPResponse(from response: URLResponse, data: Data) throws -> HTTPURLResponse {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "ChapterAudioService",
                code: 1000,
                userInfo: [NSLocalizedDescriptionKey: "Invalid timed audio response."]
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unexpected response"
            throw NSError(domain: "ChapterAudioService", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
        }

        return httpResponse
    }

    private func url(from value: String) throws -> URL {
        guard let url = URL(string: value) else {
            throw NSError(
                domain: "ChapterAudioService",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey: "Invalid timed audio URL."]
            )
        }
        return url
    }

    private func touch(_ cacheKey: String) {
        guard var entry = metadata[cacheKey] else { return }
        entry.lastAccessedAt = Date()
        metadata[cacheKey] = entry
        persistMetadata()
    }

    private func pruneCacheIfNeeded() {
        let staleEntries = metadata.values.sorted { $0.lastAccessedAt < $1.lastAccessedAt }
            .prefix(max(metadata.count - cacheLimit, 0))

        for entry in staleEntries {
            let fileURL = cacheDirectoryURL.appendingPathComponent(entry.audioRelativePath, isDirectory: false)
            try? fileManager.removeItem(at: fileURL)

            let chapterFolder = fileURL.deletingLastPathComponent()
            try? fileManager.removeItem(at: chapterFolder)
            metadata.removeValue(forKey: entry.cacheKey)
        }
    }

    private func purgeMissingFiles() {
        let invalidKeys = metadata.compactMap { key, entry -> String? in
            let fileURL = cacheDirectoryURL.appendingPathComponent(entry.audioRelativePath, isDirectory: false)
            return fileManager.fileExists(atPath: fileURL.path) && !entry.cues.isEmpty ? nil : key
        }

        guard !invalidKeys.isEmpty else { return }
        invalidKeys.forEach { metadata.removeValue(forKey: $0) }
        persistMetadata()
    }

    private func loadMetadata() {
        guard let data = try? Data(contentsOf: metadataURL),
              let entries = try? JSONDecoder().decode([ChapterAudioCacheEntry].self, from: data) else {
            metadata = [:]
            return
        }

        metadata = Dictionary(uniqueKeysWithValues: entries.map { ($0.cacheKey, $0) })
    }

    private func persistMetadata() {
        let entries = metadata.values.sorted { $0.lastAccessedAt > $1.lastAccessedAt }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: metadataURL, options: .atomic)
    }

    private func safeFilename(from value: String) -> String {
        let invalidCharacters = CharacterSet.alphanumerics.inverted
        return value
            .components(separatedBy: invalidCharacters)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }

    private func cleanSubscriptsAndSuperscripts(_ text: String) -> String {
        var cleaned = text

        // Remove bracketed numbers or footnote letters like [1], [a], etc.
        if let bracketRegex = try? NSRegularExpression(pattern: "\\[[0-9a-zA-Z]+\\]", options: []) {
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            cleaned = bracketRegex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
        }

        // Remove unicode subscripts and superscripts (both numbers, signs, and phonetic/letters)
        let pattern = "[⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁼⁽⁾ⁿ₀₁₂₃₄₅₆₇₈₉₊₋₌₍₎ᵃᵇᶜᵈᵉᶠᵍʰⁱʲᵏˡᵐⁿᵒᵖʳˢᵗᵘᵛʷˣʸᶻᴬᴮᴰᴱᴳᴴᴵᴶᴷᴸᴹᴺᴼᴾᴿᵀᵁⱽᵂₐₑₒₓₔₕₖₗₘₙₚₛₜ]"
        if let charRegex = try? NSRegularExpression(pattern: pattern, options: []) {
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            cleaned = charRegex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
        }

        // Normalize multiple spaces caused by removals
        cleaned = cleaned.replacingOccurrences(of: "  ", with: " ")

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

fileprivate final class BackgroundMusicPlayer {
    private var player: AVAudioPlayer?
    private var currentTrackName: String?
    private let resourceExtension = "mp3"

    func playIfEnabled(_ isEnabled: Bool, volume: Double, selectedTrack: String?) {
        guard isEnabled else {
            stop()
            return
        }

        do {
            try configureAudioSession()
            let player = try preparedPlayer(selectedTrack: selectedTrack)
            player.volume = Float(min(max(volume, 0), 1))
            if !player.isPlaying {
                player.play()
            }
        } catch {
            print("Background music unavailable: \(error.localizedDescription)")
        }
    }

    func pause() {
        player?.pause()
    }

    func setVolume(_ volume: Double) {
        player?.volume = Float(min(max(volume, 0), 1))
    }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        player = nil
        currentTrackName = nil
    }

    private func preparedPlayer(selectedTrack: String?) throws -> AVAudioPlayer {
        let requestedTrack = selectedTrack?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let player, currentTrackName == requestedTrack {
            return player
        }

        player?.stop()
        player?.currentTime = 0
        self.player = nil

        let candidates = resourceCandidates(for: requestedTrack)
        guard let url = candidates.compactMap({ candidate in
            Bundle.main.url(forResource: candidate, withExtension: resourceExtension)
        }).first else {
            throw NSError(
                domain: "BackgroundMusicPlayer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Add background_audio1.mp3, background_audio2.mp3, or a legacy background track to the app bundle to enable background music."]
            )
        }

        let player = try AVAudioPlayer(contentsOf: url)
        player.numberOfLoops = -1
        player.volume = 0.12
        player.prepareToPlay()
        self.player = player
        currentTrackName = requestedTrack
        return player
    }

    private func resourceCandidates(for selectedTrack: String?) -> [String] {
        var candidates: [String] = []
        if let selectedTrack, !selectedTrack.isEmpty {
            candidates.append(selectedTrack)
        }

        for candidate in ["background_audio1", "background_audio2", "bkgdmusic"] {
            if !candidates.contains(candidate) {
                candidates.append(candidate)
            }
        }

        return candidates
    }

    private func configureAudioSession() throws {
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try AVAudioSession.sharedInstance().setActive(true)
    }
}

@MainActor
final class ReadingPlaybackController: NSObject, ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var isPaused = false
    @Published private(set) var isMuted = false
    @Published var timingMode: PlaybackTimingMode = .remoteAudio
    @Published private(set) var activeVerse: Int = 1
    @Published var isPreparingAudio = false
    @Published private(set) var timeRemaining: Double? = nil
    @Published private(set) var audioStatusMessage: String?
    @Published private(set) var isUsingExactVerseAudio = false
    /// Set true whenever every configured audio endpoint has just failed
    /// for the current chapter. A reader view can watch this and present
    /// SessionLogView so logs are reachable on-device without Xcode.
    @Published var shouldPresentSessionLogs = false

    private weak var model: ModelData?
    private var backend: VersePlaybackBackend?
    private var preparationTask: Task<Void, Never>?
    private let audioService = ChapterAudioService.shared
    private var currentAudioDescriptor: ChapterAudioDescriptor?
    @Published private(set) var chapterAudioPackage: ChapterAudioPackage?
    private var audioPreparationToken = UUID()
    private let backgroundMusicPlayer = BackgroundMusicPlayer()

    private let monitor = NWPathMonitor()
    @Published var isNetworkAvailable = true

    var hasChapterAudio: Bool {
        chapterAudioPackage != nil
    }


    override init() {
        super.init()
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isNetworkAvailable = path.status == .satisfied
            }
        }
        let queue = DispatchQueue(label: "NetworkMonitor")
        monitor.start(queue: queue)

        // Set up status callback for audio service
        Task {
            await audioService.setStatusCallback { [weak self] message in
                    self?.audioStatusMessage = message
            }
        }
        setupCallbacks()
    }

    // ReadingPlaybackController.swift
    func setupCallbacks() {
        guard let model else { return }

        model.onShouldAutoStartPlayback = { [weak self] in
            self?.startPlayback()
        }

        model.onAutoAdvanceChapter = { [weak self] in
            guard let self, let model = self.model else { return }
            let nextChapter = model.chapterno + 1
            if nextChapter < model.books[model.bookno].count {
                model.setChapter(nextChapter, true)
            } else {
                self.stopPlayback()
            }
        }
    }
    
    deinit {
        monitor.cancel()
    }

    func attach(model: ModelData) {
        self.model = model
        activeVerse = max(1, model.scrollVerseNo)
        model.isPlaying = isPlaying

        // If the chapter context (book, chapter, version, voice) hasn't changed,
        // avoid re-preparing the chapter. This prevents audio from stopping
        // when the ReaderView is recreated during tab switches.
        let newDescriptor = currentDescriptor(from: model)
        if newDescriptor != currentAudioDescriptor || !hasChapterAudio {
            prepareCurrentChapter()
        }
    }

    func togglePlayback() {
        isPlaying ? pausePlayback() : startPlayback()
    }

    func toggleSpeechMuted() {
        guard isPlaying else {
            isMuted = true
            startPlayback()
            return
        }

        isMuted.toggle()
        restartPlaybackPreservingCurrentVerse()
    }

    func startPlayback() {
        startPlayback(from: nil)
    }

    private func startPlayback(from verseOverride: Int?) {
        guard let model else { return }
        let verses = currentVerseTexts(from: model)
        guard !verses.isEmpty else { return }

        if isPaused && verseOverride == nil {
            backend?.resume()
            isPlaying = true
            isPaused = false
            model.isPlaying = true
            return
        }

        backend?.stop()
        isUsingExactVerseAudio = false

        let desiredStartVerse = verseOverride
            ?? (model.searchVerseNo > 0 ? Int(model.searchVerseNo) : model.scrollVerseNo)
        let startVerse = normalizedVerse(desiredStartVerse, upperBound: verses.count)

        activeVerse = startVerse
        model.scrollVerseNo = startVerse
        if verseOverride == nil {
            model.searchVerseNo = -1
        }

        // Verify that chapterAudioPackage matches the active book/chapter/version
        var verifiedPackage: ChapterAudioPackage? = nil
        if let package = chapterAudioPackage,
           package.bookNumber == model.bookno,
           package.chapterNumber == model.chapterno,
           package.version == model.version {
            verifiedPackage = package
        }

        let selectedMode: PlaybackTimingMode = effectiveTimingMode

        let context = VersePlaybackContext(
            verseTexts: verses,
            startingVerse: startVerse,
            chapterAudioPackage: selectedMode == .remoteAudio ? verifiedPackage : nil,
            playbackSpeed: model.playbackSpeed,
            playbackVolume: Float(model.playbackVolume)
        )

        let backend = makeBackend(for: selectedMode)
        self.backend = backend
        func startBackend() {
            backend.start(
                context: context,
                onAdvance: { [weak self] verse in
                    DispatchQueue.main.async {
                        self?.advance(to: verse)
                    }
                },
                onTimeUpdate: { [weak self] remaining in
                    DispatchQueue.main.async {
                        self?.timeRemaining = remaining
                    }
                },
                onFinish: { [weak self] in
                    DispatchQueue.main.async {
                        guard let self = self, let model = self.model else { return }
                        self.stopPlayback(resetSearch: false)
                        self.activeVerse = 1
                        model.searchVerseNo = -1

                        // Clear audio package and descriptor when reading completes
                        self.chapterAudioPackage = nil
                        self.currentAudioDescriptor = nil
                        self.isUsingExactVerseAudio = false

                        if model.continuousPlayEnabled {
                            if model.isInReadingMode {
                                model.onAutoAdvanceReadingPlan?()
                            } else {
                                model.onAutoAdvanceChapter?()
                            }
                        }
                    }
                }
            )
        }

        // Title is now included in the text sent to the audio server, so no separate announcement needed
        startBackend()

        isPlaying = true
        isPaused = false
        model.isPlaying = true
        syncBackgroundMusic()

        if isMuted {
            isUsingExactVerseAudio = false
            audioStatusMessage = "Playback muted. Continuing with scrolling only."
            prepareCurrentChapter()
        } else if timingMode == .remoteAudio {
            isUsingExactVerseAudio = verifiedPackage != nil
            audioStatusMessage = verifiedPackage == nil
                ? "Scrolling now. Timed chapter audio will join when ready."
                : "Playing timed chapter audio."
            prepareCurrentChapter()
        } else {
            audioStatusMessage = "Using estimated verse timing."
        }
    }

    func stopPlayback(resetSearch: Bool = false) {
        preparationTask?.cancel()
        backend?.stop()
        backend = nil
        isPlaying = false
        isPaused = false
        isMuted = false
        isPreparingAudio = false
        timeRemaining = nil
        isUsingExactVerseAudio = false
        model?.isPlaying = false
        backgroundMusicPlayer.stop()

        // Cancel all in-flight audio requests when stopping playback
        Task {
            await audioService.cancelAllRequests()
        }

        if resetSearch {
            model?.searchVerseNo = -1
        }

        deactivateAudioSessionIfNeeded()
    }

    func pausePlayback() {
        guard isPlaying else { return }
        backend?.pause()
        isPlaying = false
        isPaused = true
        model?.isPlaying = false
        syncBackgroundMusic()
    }

    func resumePlayback() {
        guard isPaused else {
            if !isPlaying {
                startPlayback()
            }
            return
        }

        backend?.resume()
        isPlaying = true
        isPaused = false
        model?.isPlaying = true
        syncBackgroundMusic()
    }

    func togglePlayPause() {
        if isPlaying {
            pausePlayback()
        } else if isPaused {
            resumePlayback()
        } else {
            startPlayback()
        }
    }

    func seek(to verse: Int) {
        guard let model else { return }
        let maxVerse = currentVerseTexts(from: model).count
        let normalized = normalizedVerse(verse, upperBound: maxVerse)
        activeVerse = normalized
        model.scrollVerseNo = normalized

        if isPlaying {
            backend?.seek(to: normalized)
        } else if isPaused {
            startPlayback(from: normalized)
            pausePlayback()
        }
    }

    func handleChapterChange() {
        audioPreparationToken = UUID()
        stopPlayback()
        activeVerse = 1
        chapterAudioPackage = nil
        currentAudioDescriptor = nil
        isUsingExactVerseAudio = false
        audioStatusMessage = "Preparing timed audio..."

        // Cancel any in-flight audio requests to prevent old audio from arriving
        Task {
            await audioService.cancelAllRequests()
        }

        prepareCurrentChapter()
    }

    func selectTimingMode(_ mode: PlaybackTimingMode) {
        timingMode = mode
        if mode == .remoteAudio {
            prepareCurrentChapter()
        }
        guard isPlaying else { return }
        startPlayback()
    }

    /// Manual trigger, e.g. for a "View session logs" debug button, in
    /// addition to the automatic prompt on total audio failure.
    func presentSessionLogs() {
        shouldPresentSessionLogs = true
    }

    func handleBackgroundMusicPreferenceChange() {
        syncBackgroundMusic()
    }

    func handleBackgroundMusicVolumeChange() {
        guard let model else { return }
        backgroundMusicPlayer.setVolume(model.backgroundMusicVolume)
    }

    func handlePlaybackVolumeChange() {
        guard let model else { return }
        let volume = Float(min(max(model.playbackVolume, 0), 1))
        backend?.setVolume(volume)
    }

    func prepareCurrentChapter() {
        guard let model else { return }
        let verses = currentVerseTexts(from: model)
        guard !verses.isEmpty else {
            chapterAudioPackage = nil
            audioStatusMessage = nil
            return
        }

        guard let descriptor = currentDescriptor(from: model) else { return }
        currentAudioDescriptor = descriptor
        let token = UUID()
        audioPreparationToken = token
        preparationTask?.cancel()
        preparationTask = Task { [weak self] in
            await self?.prepareChapterAudio(for: model, descriptor: descriptor, verses: verses, token: token)
        }
    }

    private func prepareChapterAudio(
        for model: ModelData,
        descriptor: ChapterAudioDescriptor,
        verses: [String],
        token: UUID
    ) async {
        // If offline, skip remote audio and use fallback
        guard isNetworkAvailable else {
            await MainActor.run {
                guard shouldApplyAudioResult(for: descriptor, token: token) else { return }
                chapterAudioPackage = nil
                isPreparingAudio = false
                isUsingExactVerseAudio = false
                audioStatusMessage = "Offline: Using estimated verse timing."
            }
            return
        }
        let endpoints = chapterAudioEndpoints
        await audioService.cancelAllRequests(except: [descriptor.cacheKey])

        if let cached = await audioService.cachedChapterAudioPackage(for: descriptor) {
            guard shouldApplyAudioResult(for: descriptor, token: token) else { return }
            guard cached.bookNumber == model.bookno &&
                  cached.chapterNumber == model.chapterno &&
                  cached.version == model.version else {
                logSession("Cached package mismatch ignored")
                chapterAudioPackage = nil
                isPreparingAudio = false
                isUsingExactVerseAudio = false
                audioStatusMessage = "Cached audio mismatch."
                return
            }
            chapterAudioPackage = cached
            isPreparingAudio = false
            if isPlaying && timingMode == .remoteAudio {
                attachChapterAudioIfNeeded(cached)
            } else {
                audioStatusMessage = "Timed chapter audio cached on this device."
            }
            prefetchNextChapter(after: descriptor)
            return
        }

        guard !endpoints.isEmpty else {
            guard shouldApplyAudioResult(for: descriptor, token: token) else { return }
            chapterAudioPackage = nil
            isPreparingAudio = false
            isUsingExactVerseAudio = false
            audioStatusMessage = "No audio endpoints configured."
            return
        }

        isPreparingAudio = true
        audioStatusMessage = "Preparing timed audio..."

        let prepared = await audioService.prepareChapterAudioPackage(for: descriptor, verses: verses, endpoints: endpoints)
        guard !Task.isCancelled, shouldApplyAudioResult(for: descriptor, token: token) else { return }

        isPreparingAudio = false

        if let prepared,
           prepared.bookNumber == model.bookno,
           prepared.chapterNumber == model.chapterno,
           prepared.version == model.version {
            chapterAudioPackage = prepared
            if isPlaying && timingMode == .remoteAudio {
                attachChapterAudioIfNeeded(prepared)
            } else {
                isUsingExactVerseAudio = false
                audioStatusMessage = "Timed chapter audio ready."
            }
            prefetchNextChapter(after: descriptor)
        } else {
            chapterAudioPackage = nil
            isUsingExactVerseAudio = false
            if isPlaying && timingMode == .remoteAudio {
                audioStatusMessage = "Timed audio unavailable. Continuing with estimated scrolling."
            } else {
                audioStatusMessage = "Timed audio unavailable or mismatched."
            }
            // Every endpoint failed for this chapter — surface the session
            // log so it can be copied off-device without needing Xcode.
            shouldPresentSessionLogs = true
        }
    }

    private func prefetchNextChapter(after descriptor: ChapterAudioDescriptor) {
        guard let model = self.model else { return }

        var nextBookNo = descriptor.bookNumber
        var nextChapterNo = descriptor.chapterNumber + 1

        // If the next chapter exceeds the count of the current book, move to the first chapter of the next book
        if nextChapterNo >= model.books[nextBookNo].count {
            nextBookNo += 1
            nextChapterNo = 0
        }

        // Ensure we haven't gone past the last book (Revelation)
        guard nextBookNo < model.books.count else { return }

        let titles = model.GetTitles()
        guard titles.indices.contains(nextBookNo) else { return }

        let nextDescriptor = ChapterAudioDescriptor(
            voice: preferredVoiceSelection,
            bookNumber: nextBookNo,
            chapterNumber: nextChapterNo,
            bookTitle: titles[nextBookNo],
            version: descriptor.version
        )

        let nextVerses = model.books[nextBookNo][nextChapterNo].verses.map(\.text)
        let endpoints = chapterAudioEndpoints

        Task {
            _ = await audioService.prepareChapterAudioPackage(for: nextDescriptor, verses: nextVerses, endpoints: endpoints)
        }
    }

    private func attachChapterAudioIfNeeded(_ package: ChapterAudioPackage) {
        guard let model else { return }
        guard package.bookNumber == model.bookno &&
              package.chapterNumber == model.chapterno &&
              package.version == model.version else {
            logSession("Audio package mismatch. Expected: \(model.bookno)-\(model.chapterno)-\(model.version), got: \(package.bookNumber)-\(package.chapterNumber)-\(package.version)")
            // Force clear any mismatched audio package
            chapterAudioPackage = nil
            isUsingExactVerseAudio = false
            audioStatusMessage = "Timed audio ignored because it belongs to another chapter."
            return
        }
        guard let remoteBackend = backend as? RemoteTimedAudioPlaybackBackend else { return }
        remoteBackend.attachChapterAudioPackage(package, currentVerse: activeVerse)
        isUsingExactVerseAudio = true
        audioStatusMessage = "Timed chapter audio joined at verse \(activeVerse)."
        syncBackgroundMusic()
    }

    private func shouldApplyAudioResult(for descriptor: ChapterAudioDescriptor, token: UUID) -> Bool {
        guard token == audioPreparationToken,
              let model,
              let currentDescriptor = currentDescriptor(from: model) else {
            return false
        }

        return currentDescriptor.cacheKey == descriptor.cacheKey
    }

    private func advance(to verse: Int) {
        guard let model else { return }
        activeVerse = verse
        model.scrollVerseNo = verse
    }

    private func restartPlaybackPreservingCurrentVerse() {
        guard isPlaying else { return }
        startPlayback(from: activeVerse)
    }

    private func makeBackend(for mode: PlaybackTimingMode) -> VersePlaybackBackend {
        switch mode {
        case .timedText:
            return TimedVersePlaybackBackend()
        case .remoteAudio:
            return RemoteTimedAudioPlaybackBackend()
        }
    }

    private func currentVerseTexts(from model: ModelData) -> [String] {
        guard model.books.indices.contains(model.bookno),
              model.books[model.bookno].indices.contains(model.chapterno) else {
            return []
        }

        return model.books[model.bookno][model.chapterno].verses.map(\.text)
    }

    private func currentDescriptor(from model: ModelData) -> ChapterAudioDescriptor? {
        guard model.books.indices.contains(model.bookno),
              model.books[model.bookno].indices.contains(model.chapterno),
              model.GetTitles().indices.contains(model.bookno) else {
            return nil
        }

        return ChapterAudioDescriptor(
            voice: preferredVoiceSelection,
            bookNumber: model.bookno,
            chapterNumber: model.chapterno,
            bookTitle: model.GetTitles()[model.bookno],
            version: model.version
        )
    }

    private var preferredVoiceSelection: ChapterVoiceSelection {
        ChapterVoiceSelection.from(userDefaultsValue: UserDefaults.standard.string(forKey: "selectedVoice"))
    }

    private var effectiveTimingMode: PlaybackTimingMode {
        isMuted ? .timedText : timingMode
    }

    private func syncBackgroundMusic() {
        guard let model else {
            backgroundMusicPlayer.stop()
            return
        }

        let isAudioActive = isPlaying || isPaused
        let shouldPlayMusic = isAudioActive && !isMuted && effectiveTimingMode != .timedText
        if shouldPlayMusic {
            backgroundMusicPlayer.playIfEnabled(
                model.backgroundMusicEnabled,
                volume: model.backgroundMusicVolume,
                selectedTrack: model.backgroundMusicTrack
            )
        } else {
            backgroundMusicPlayer.stop()
        }
    }

    /// The three servers, tried in order. Put whichever one you trust most
    /// / is cheapest / is fastest first — a failure just falls through to
    /// the next adapter (see ChapterAudioService.prepareChapterAudioPackage).
    ///
    /// The local dev server's URL can be overridden at runtime via
    /// UserDefaults "chapterAudioServiceURL" (e.g. "http://10.0.0.40:3000/api/audio"
    /// when testing on a physical device against your Mac on the LAN).
    /// Without that override, "localhost" only makes sense on the simulator
    /// (where it really does mean your Mac) — on a physical device it means
    /// the device itself, so the request is guaranteed to fail with
    /// "Connection refused." Skip it there instead of wasting the attempt.
    private var chapterAudioEndpoints: [ChapterAudioEndpoint] {
        var endpoints: [ChapterAudioEndpoint] = [MirrorAPIEndpoint(), MikeTTSEndpoint()]
        
        if let overrideURLString = UserDefaults.standard.string(forKey: "chapterAudioServiceURL"),
           let overrideURL = URL(string: overrideURLString), !overrideURLString.isEmpty {
            endpoints.append(LocalDevEndpoint(url: overrideURL))
        } else if let configuredLANURL = configuredLANAudioServiceURL {
            endpoints.append(LocalDevEndpoint(url: configuredLANURL))
        } else {
            #if targetEnvironment(simulator)
            endpoints.append(LocalDevEndpoint())
            #else
            logSession("Skipping local-dev endpoint: no LAN audio-service URL is configured, so \"localhost\" would just be the device itself.")
            #endif
        }

        return endpoints
    }
    
    /// The release configuration may include a LAN HTTP endpoint in
    /// `ChapterAudioServiceFallbackURLs`. Prefer a UserDefaults override for
    /// ad-hoc development, then use that configured endpoint as the last
    /// fallback on a physical device.
    private var configuredLANAudioServiceURL: URL? {
        let urls = Bundle.main.object(forInfoDictionaryKey: "ChapterAudioServiceFallbackURLs") as? [String] ?? []
        return urls
            .compactMap { URL(string: $0) }
            .first { $0.scheme == "http" && $0.host != "localhost" && $0.host != "127.0.0.1" }
    }

    private func normalizedVerse(_ verse: Int, upperBound: Int) -> Int {
        guard upperBound > 0 else { return 1 }
        return min(Swift.max(verse, 1), upperBound)
    }

    private func deactivateAudioSessionIfNeeded() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            print("Audio session deactivation failed: \(error.localizedDescription)")
        }
    }
}

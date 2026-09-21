import Foundation
import AVFoundation
import Speech
import CacaoTransCore

/// macOS 26 以降の SpeechAnalyzer（オンデバイス）による日本語音声認識。
public final class SpeechTranscriptionService {
    public struct Output: Sendable {
        public var tokens: [WordToken]
        public var duration: Double
    }

    public let locale: Locale

    public init(localeIdentifier: String = "ja-JP") {
        self.locale = Locale(identifier: localeIdentifier)
    }

    public static var isAvailable: Bool { SpeechTranscriber.isAvailable }

    /// 言語モデルが未ダウンロードならダウンロードする。
    public func prepare(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let transcriber = try await makeTranscriber()
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            let observation = progress.map { cb in
                request.progress.observe(\.fractionCompleted, options: [.new]) { p, _ in cb(p.fractionCompleted) }
            }
            defer { observation?.invalidate() }
            try await request.downloadAndInstall()
        }
        progress?(1)
    }

    /// ファイル全体を認識して単語列を返す。progress は 0...1。
    public func transcribe(url: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> Output {
        try await prepare()
        let transcriber = try await makeTranscriber()
        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let collector = Task<[WordToken], Error> {
            var tokens: [WordToken] = []
            for try await result in transcriber.results {
                tokens.append(contentsOf: Self.tokens(from: result))
                if duration > 0 {
                    progress?(min(0.99, result.range.end.seconds / duration))
                }
            }
            return tokens
        }

        do {
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            throw error
        }

        let tokens = try await collector.value
        progress?(1)
        return Output(tokens: tokens, duration: duration)
    }

    // MARK: - Internals

    private func makeTranscriber() async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable else { throw SpeechServiceError.unavailable }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw SpeechServiceError.localeUnsupported(locale.identifier)
        }
        return SpeechTranscriber(
            locale: supported,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
    }

    /// 認識結果（AttributedString）を時刻付きトークンへ分解する。
    static func tokens(from result: SpeechTranscriber.Result) -> [WordToken] {
        let text = result.text
        var out: [WordToken] = []
        var fallbackStart = result.range.start.seconds
        let fallbackEnd = result.range.end.seconds
        for run in text.runs {
            let piece = String(text[run.range].characters)
            guard !piece.isEmpty else { continue }
            if let tr = run.audioTimeRange {
                let s = tr.start.seconds
                let e = tr.end.seconds
                out.append(WordToken(text: piece, start: s, end: max(e, s)))
                fallbackStart = max(fallbackStart, e)
            } else {
                out.append(WordToken(text: piece, start: fallbackStart, end: fallbackEnd))
            }
        }
        return out
    }
}

public enum SpeechServiceError: Error, LocalizedError {
    case unavailable
    case localeUnsupported(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable: return "この Mac では音声認識（SpeechAnalyzer）が利用できません。macOS 26 以降が必要です。"
        case .localeUnsupported(let id): return "音声認識がこの言語に対応していません: \(id)"
        }
    }
}

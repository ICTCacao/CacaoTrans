import Foundation
import CacaoTransCore

/// 音声ファイル → 文字起こし（話者付き）→ Claude 校正 までを一気通貫で実行する。
public struct PipelineOptions: Sendable, Equatable {
    public var useDiarization: Bool = true
    public var useClaude: Bool = true
    public var claude: ClaudeConfig?
    public var refiner: RefinerOptions = RefinerOptions()
    public var assigner: SpeakerAssigner.Options = SpeakerAssigner.Options()

    public init() {}
}

public enum PipelineStage: String, Sendable, CaseIterable {
    case loading = "音声を読み込み中"
    case preparingModels = "認識モデルを準備中"
    case transcribing = "文字起こし中"
    case diarizing = "話者分離中"
    case assembling = "発話を組み立て中"
    case refining = "Claude で校正中"
    case done = "完了"
}

public struct PipelineProgress: Sendable {
    public var stage: PipelineStage
    /// 全体の進捗 0...1
    public var fraction: Double
    public var detail: String
    public init(stage: PipelineStage, fraction: Double, detail: String = "") {
        self.stage = stage
        self.fraction = fraction
        self.detail = detail
    }
}

public struct PipelineResult: Sendable {
    public var transcript: Transcript
    /// Claude 校正で失敗したチャンク数（0 なら全部成功、Claude 未使用も 0）。
    public var refineFailedChunks: Int
    public var refineTotalChunks: Int
    public var refineError: String?
    public var warning: String? {
        guard refineFailedChunks > 0 else { return nil }
        return "Claude の校正が \(refineTotalChunks) ブロック中 \(refineFailedChunks) ブロックで失敗しました。その部分は認識結果のままです。「文字起こし」メニューの「Claude で校正だけやり直す」で再試行できます。" + (refineError.map { "\n\n原因: \($0)" } ?? "")
    }
}

public actor TranscriptionPipeline {
    public init() {}

    public func run(url: URL,
                    options: PipelineOptions,
                    progress: @escaping @Sendable (PipelineProgress) -> Void) async throws -> Transcript {
        try await runDetailed(url: url, options: options, progress: progress).transcript
    }

    public func runDetailed(url: URL,
                            options: PipelineOptions,
                            progress: @escaping @Sendable (PipelineProgress) -> Void) async throws -> PipelineResult {
        guard AudioLoader.isSupported(url) else {
            throw AudioLoaderError.unsupported(url.pathExtension)
        }
        progress(PipelineProgress(stage: .loading, fraction: 0.01))
        let duration = try AudioLoader.duration(of: url)

        // 進捗の重み配分
        let wTranscribe = options.useDiarization ? 0.45 : 0.75
        let wDiarize = options.useDiarization ? 0.30 : 0.0
        let wRefine = options.useClaude ? 0.20 : 0.0
        let base = 0.03

        let speech = SpeechTranscriptionService()
        progress(PipelineProgress(stage: .preparingModels, fraction: base))
        try await speech.prepare { p in
            progress(PipelineProgress(stage: .preparingModels, fraction: base, detail: "言語モデルをダウンロード中 \(Int(p * 100))%"))
        }

        let state = ProgressState()

        async let transcription: SpeechTranscriptionService.Output = speech.transcribe(url: url) { p in
            Task { await state.set(transcribe: p) }
            let f = base + p * wTranscribe
            progress(PipelineProgress(stage: .transcribing, fraction: f, detail: "\(Transcript.formatTime(p * duration)) / \(Transcript.formatTime(duration))"))
        }

        async let turns: [SpeakerTurn] = {
            guard options.useDiarization else { return [] }
            let samples = try AudioLoader.loadMono16k(url)
            let service = DiarizationService()
            return try await service.diarize(samples: samples) { p in
                Task { await state.set(diarize: p) }
                progress(PipelineProgress(stage: .diarizing, fraction: base + wTranscribe * 0.0 + p * wDiarize, detail: p < 0.2 ? "話者分離モデルを準備中" : "話者を分離中"))
            }
        }()

        let speechOut = try await transcription
        let speakerTurns = try await turns

        progress(PipelineProgress(stage: .assembling, fraction: base + wTranscribe + wDiarize))
        let segments = SpeakerAssigner.makeSegments(tokens: speechOut.tokens, turns: speakerTurns, options: options.assigner)
        var transcript = Transcript(sourceFileName: url.lastPathComponent, duration: speechOut.duration, segments: segments)

        var result = PipelineResult(transcript: transcript, refineFailedChunks: 0, refineTotalChunks: 0, refineError: nil)
        if options.useClaude, let config = options.claude {
            let refiner = TranscriptRefiner(client: ClaudeClient(config: config), options: options.refiner)
            let start = base + wTranscribe + wDiarize
            let outcome = await refiner.refineTolerant(transcript) { rp in
                progress(PipelineProgress(stage: .refining,
                                          fraction: start + rp.fraction * wRefine,
                                          detail: "\(rp.completedChunks)/\(rp.totalChunks) ブロック・入力 \(rp.usage.inputTokens) / 出力 \(rp.usage.outputTokens) トークン"))
            }
            result.transcript = outcome.transcript
            result.refineFailedChunks = outcome.failedChunks
            result.refineTotalChunks = outcome.totalChunks
            result.refineError = outcome.lastErrorDescription
        }
        progress(PipelineProgress(stage: .done, fraction: 1))
        return result
    }
}

/// 並列に走る2つの進捗を保持する（表示は片方ずつで十分なので現状は記録のみ）。
actor ProgressState {
    var transcribe: Double = 0
    var diarize: Double = 0
    func set(transcribe p: Double) { transcribe = p }
    func set(diarize p: Double) { diarize = p }
}

import Foundation
import FluidAudio
import CacaoTransCore

/// FluidAudio（CoreML 版 pyannote）による話者分離。初回はモデルをダウンロードする。
public final class DiarizationService {
    public init() {}

    /// 16kHz モノラルの PCM を渡す。
    public func diarize(samples: [Float], progress: (@Sendable (Double) -> Void)? = nil) async throws -> [SpeakerTurn] {
        progress?(0.05)
        let manager = OfflineDiarizerManager(config: OfflineDiarizerConfig())
        try await manager.prepareModels()
        progress?(0.2)
        let result = try await manager.process(audio: samples)
        progress?(1)
        return result.segments.map {
            SpeakerTurn(speakerID: String(describing: $0.speakerId),
                        start: Double($0.startTimeSeconds),
                        end: Double($0.endTimeSeconds))
        }
    }
}

import Foundation
import AVFoundation
import CacaoTransCore

/// プロジェクトに同梱するために音声を AAC（モノラル・低ビットレート）へ圧縮する。
/// 会話の聞き取り用途なので、1時間あたり 20MB 程度に収まる設定にしている。
public enum AudioCompressor {
    public static let fileExtension = "m4a"
    public static let sampleRate: Double = 32_000
    public static let bitRate = 48_000
    public static let codecDescription = "AAC \(bitRate / 1000)kbps モノラル"

    /// 圧縮して同梱用データを作る。圧縮しても元ファイルより小さくならなければ元ファイルをそのまま使う。
    public static func embeddedAudio(for url: URL,
                                     progress: (@Sendable (Double) -> Void)? = nil) throws -> EmbeddedAudio {
        let compressed = try compress(url, progress: progress)
        let originalSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? Int.max
        if compressed.count < originalSize {
            return EmbeddedAudio(fileExtension: fileExtension, data: compressed, codecDescription: codecDescription)
        }
        let original = try Data(contentsOf: url)
        return EmbeddedAudio(fileExtension: url.pathExtension.lowercased(), data: original, codecDescription: "元ファイルのまま")
    }

    /// AAC モノラルに変換した m4a のバイト列を返す。
    public static func compress(_ url: URL, progress: (@Sendable (Double) -> Void)? = nil) throws -> Data {
        let input = try AVAudioFile(forReading: url)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CacaoTransCompress", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(UUID().uuidString + "." + fileExtension)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate,
        ]
        let output = try AVAudioFile(forWriting: tmp, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let total = Double(max(1, input.length))
        try AudioLoader.readConverted(input, to: output.processingFormat) { buffer in
            try output.write(from: buffer)
            progress?(min(1, Double(input.framePosition) / total))
        }
        output.close()
        return try Data(contentsOf: tmp)
    }
}

import Foundation
import AVFoundation

/// 音声ファイル（mp3 / wav / m4a / aac / aiff など AVFoundation が読めるもの）の読み込みと変換。
public enum AudioLoader {
    public static let supportedExtensions = ["mp3", "wav", "m4a", "aac", "aiff", "aif", "caf", "flac", "mp4", "mov"]

    public static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// 長さ（秒）
    public static func duration(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// 16kHz モノラル Float32 の PCM 配列に変換する（話者分離モデルの入力形式）。
    public static func loadMono16k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let src = file.processingFormat
        guard let dst = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: src, to: dst) else {
            throw AudioLoaderError.cannotConvert
        }

        let chunkFrames: AVAudioFrameCount = 65_536
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: chunkFrames) else {
            throw AudioLoaderError.cannotConvert
        }
        var out: [Float] = []
        out.reserveCapacity(Int(Double(file.length) / src.sampleRate * 16_000) + 16_000)

        var reachedEnd = false
        while !reachedEnd {
            try file.read(into: inBuf, frameCount: chunkFrames)
            if inBuf.frameLength == 0 { break }
            if file.framePosition >= file.length { reachedEnd = true }

            let ratio = dst.sampleRate / src.sampleRate
            let outCapacity = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 1024
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: outCapacity) else {
                throw AudioLoaderError.cannotConvert
            }
            var consumed = false
            var convError: NSError?
            let status = converter.convert(to: outBuf, error: &convError) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return inBuf
            }
            if let convError { throw convError }
            if status == .error { throw AudioLoaderError.cannotConvert }
            if let ch = outBuf.floatChannelData, outBuf.frameLength > 0 {
                out.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: Int(outBuf.frameLength)))
            }
        }
        // 変換器に残ったサンプルを吐き出す
        if let tail = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: 8192) {
            var convError: NSError?
            _ = converter.convert(to: tail, error: &convError) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }
            if let ch = tail.floatChannelData, tail.frameLength > 0 {
                out.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: Int(tail.frameLength)))
            }
        }
        return out
    }
}

public enum AudioLoaderError: Error, LocalizedError {
    case cannotConvert
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .cannotConvert: return "音声を PCM に変換できませんでした。"
        case .unsupported(let ext): return "対応していない拡張子です: .\(ext)"
        }
    }
}

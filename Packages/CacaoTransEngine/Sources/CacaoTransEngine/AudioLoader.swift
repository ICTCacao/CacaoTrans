import Foundation
import AVFoundation

/// 音声ファイル（mp3 / wav / m4a / aac / aiff など AVFoundation が読めるもの）の読み込みと変換。
public enum AudioLoader {
    public static let supportedExtensions = ["mp3", "wav", "m4a", "aac", "aiff", "aif", "caf", "flac", "mp4", "mov"]

    public static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// AVAudioFile を開く。中身を音声として解釈できないときは、原因が分かる日本語のエラーにする。
    public static func open(_ url: URL) throws -> AVAudioFile {
        do {
            return try AVAudioFile(forReading: url)
        } catch let error as NSError where unreadableCodes.contains(error.code) {
            throw AudioLoaderError.unreadable(url.lastPathComponent)
        }
    }

    /// 'dta?' 不正なファイル / 'typ?' 未対応のファイル形式 / 'fmt?' 未対応のデータ形式 / 'wht?' 不明
    private static let unreadableCodes: Set<Int> = [1685348671, 1954115647, 1718449215, 2003334207]

    /// 長さ（秒）
    public static func duration(of url: URL) throws -> Double {
        let file = try open(url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// 16kHz モノラル Float32 の PCM 配列に変換する（話者分離モデルの入力形式）。
    public static func loadMono16k(_ url: URL) throws -> [Float] {
        let file = try open(url)
        guard let dst = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false) else {
            throw AudioLoaderError.cannotConvert
        }
        var out: [Float] = []
        out.reserveCapacity(Int(Double(file.length) / file.processingFormat.sampleRate * 16_000) + 16_000)
        try readConverted(file, to: dst) { buf in
            if let ch = buf.floatChannelData {
                out.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength)))
            }
        }
        return out
    }

    /// ファイルを頭から読み、dst の形式に変換したバッファを順に sink へ渡す。
    static func readConverted(_ file: AVAudioFile, to dst: AVAudioFormat,
                              chunkFrames: AVAudioFrameCount = 65_536,
                              sink: (AVAudioPCMBuffer) throws -> Void) throws {
        let src = file.processingFormat
        guard let converter = AVAudioConverter(from: src, to: dst),
              let inBuf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: chunkFrames) else {
            throw AudioLoaderError.cannotConvert
        }
        let ratio = dst.sampleRate / src.sampleRate

        var reachedEnd = false
        while !reachedEnd {
            try Task.checkCancellation()
            try file.read(into: inBuf, frameCount: chunkFrames)
            if inBuf.frameLength == 0 { break }
            if file.framePosition >= file.length { reachedEnd = true }

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
            if outBuf.frameLength > 0 { try sink(outBuf) }
        }
        // 変換器に残ったサンプルを吐き出す
        if let tail = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: 8192) {
            var convError: NSError?
            _ = converter.convert(to: tail, error: &convError) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }
            if tail.frameLength > 0 { try sink(tail) }
        }
    }
}

public enum AudioLoaderError: Error, LocalizedError {
    case cannotConvert
    case unsupported(String)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .cannotConvert: return "音声を PCM に変換できませんでした。"
        case .unsupported(let ext): return "対応していない拡張子です: .\(ext)"
        case .unreadable(let name): return "「\(name)」を音声として読み込めませんでした。対応していない形式か、ファイルが壊れている可能性があります。m4a や wav に変換してからお試しください。"
        }
    }
}

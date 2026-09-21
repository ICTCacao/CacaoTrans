import Foundation

/// 音声認識が返す最小単位（単語・文節）と、その音声上の時刻。
public struct WordToken: Codable, Sendable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// 話者分離が返す「誰がいつ喋っていたか」。
public struct SpeakerTurn: Codable, Sendable, Equatable {
    public var speakerID: String
    public var start: Double
    public var end: Double

    public init(speakerID: String, start: Double, end: Double) {
        self.speakerID = speakerID
        self.start = start
        self.end = end
    }
}

/// 文字起こし結果の1行（1発話）。
public struct TranscriptSegment: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: Int
    /// 話者ラベル。"話者1" のような内部ラベル。表示名は Transcript.speakerNames で差し替える。
    public var speaker: String
    public var start: Double
    public var end: Double
    public var text: String
    /// Claude で整形する前の原文（整形していなければ nil）。
    public var originalText: String?

    public init(id: Int, speaker: String, start: Double, end: Double, text: String, originalText: String? = nil) {
        self.id = id
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
        self.originalText = originalText
    }
}

/// 1本の音声に対する文字起こし全体。プロジェクトファイル（JSON）としてそのまま保存できる。
public struct Transcript: Codable, Sendable, Equatable {
    public static let formatVersion = 1

    public var version: Int
    public var sourceFileName: String
    public var duration: Double
    public var createdAt: Date
    public var segments: [TranscriptSegment]
    /// 内部ラベル → 表示名（例: "話者1" → "田中"）。
    public var speakerNames: [String: String]
    public var notes: String
    /// 元の音声ファイルへの参照（再生用）。macOS ではセキュリティスコープ付きブックマーク。
    public var sourceBookmark: Data?
    /// 元の音声ファイルのパス（表示・再リンクの手がかり）。
    public var sourceFilePath: String?
    /// この音声の背景（Claude 校正に渡す説明）。
    public var context: String?
    /// この音声の用語集（Claude 校正に渡す）。
    public var glossary: String?

    public init(sourceFileName: String, duration: Double, segments: [TranscriptSegment], createdAt: Date = Date()) {
        self.version = Transcript.formatVersion
        self.sourceFileName = sourceFileName
        self.duration = duration
        self.createdAt = createdAt
        self.segments = segments
        self.speakerNames = [:]
        self.notes = ""
    }

    /// 登場順に並んだ話者ラベル一覧。
    public var speakers: [String] {
        var seen: [String] = []
        for s in segments where !seen.contains(s.speaker) {
            seen.append(s.speaker)
        }
        return seen.sorted { Transcript.speakerSortKey($0) < Transcript.speakerSortKey($1) }
    }

    public func displayName(for speaker: String) -> String {
        if let name = speakerNames[speaker], !name.isEmpty { return name }
        return speaker
    }

    public var fullText: String {
        segments.map(\.text).joined(separator: "\n")
    }

    public var characterCount: Int {
        segments.reduce(0) { $0 + $1.text.count }
    }

    // MARK: - Helpers

    public static func speakerLabel(index: Int) -> String {
        "話者\(index + 1)"
    }

    static func speakerSortKey(_ label: String) -> (Int, String) {
        if label.hasPrefix("話者"), let n = Int(label.dropFirst(2)) { return (n, label) }
        return (Int.max, label)
    }

    /// 秒 → "h:mm:ss" または "m:ss"
    public static func formatTime(_ seconds: Double, alwaysHours: Bool = false) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 || alwaysHours {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - JSON project file

    public static let projectFileExtension = "ccot"
    /// 以前の拡張子。開くときだけ受け付ける。
    public static let legacyProjectFileExtensions = ["cacaotrans"]
    public static var allProjectFileExtensions: [String] { [projectFileExtension] + legacyProjectFileExtensions }

    public func projectData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func fromProjectData(_ data: Data) throws -> Transcript {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Transcript.self, from: data)
    }
}

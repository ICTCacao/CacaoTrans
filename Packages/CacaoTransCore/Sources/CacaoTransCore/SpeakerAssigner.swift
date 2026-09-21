import Foundation

/// 音声認識の単語列と話者分離の結果を突き合わせ、発話（TranscriptSegment）に組み立てる。
public enum SpeakerAssigner {
    public struct Options: Sendable, Equatable {
        /// この秒数以上の無音があれば発話を区切る。
        public var maxPause: Double = 1.2
        /// 1発話の最大長（秒）。これを超えたら文の切れ目で区切る。
        public var maxSegmentSeconds: Double = 40
        /// 文末とみなす文字。
        public var sentenceEnders: Set<Character> = ["。", "？", "！", "?", "!"]
        /// これより短い話者の切り替わりは前後の話者に吸収する（分離結果のちらつき対策）。
        public var minSpeakerRunSeconds: Double = 0.6
        /// 話者分離の区間から外れた単語を、最寄りの区間に寄せる許容秒数。
        public var nearestTurnTolerance: Double = 2.0

        public init() {}
    }

    /// 話者分離結果を "話者1", "話者2" … の登場順ラベルへ正規化する。
    public static func normalizeTurns(_ turns: [SpeakerTurn]) -> [SpeakerTurn] {
        let sorted = turns.sorted { $0.start < $1.start }
        var mapping: [String: String] = [:]
        var result: [SpeakerTurn] = []
        for t in sorted {
            if mapping[t.speakerID] == nil {
                mapping[t.speakerID] = Transcript.speakerLabel(index: mapping.count)
            }
            result.append(SpeakerTurn(speakerID: mapping[t.speakerID]!, start: t.start, end: t.end))
        }
        return result
    }

    public static func makeSegments(tokens: [WordToken], turns rawTurns: [SpeakerTurn], options: Options = Options()) -> [TranscriptSegment] {
        let tokens = tokens.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start < $1.start }
        guard !tokens.isEmpty else { return [] }
        let turns = normalizeTurns(rawTurns)

        // 1. 各単語に話者を割り当てる
        var speakers: [String] = tokens.map { token in
            speaker(for: token, turns: turns, tolerance: options.nearestTurnTolerance)
        }
        // 割り当てられなかった単語は直前（なければ直後）の話者を引き継ぐ
        var last = speakers.first(where: { !$0.isEmpty }) ?? Transcript.speakerLabel(index: 0)
        for i in speakers.indices {
            if speakers[i].isEmpty { speakers[i] = last } else { last = speakers[i] }
        }

        // 2. 短すぎる話者切り替わりを吸収する
        smoothShortRuns(tokens: tokens, speakers: &speakers, minRun: options.minSpeakerRunSeconds)

        // 3. 発話にまとめる
        var segments: [TranscriptSegment] = []
        var current: [WordToken] = []
        var currentSpeaker = speakers[0]

        func flush() {
            guard let first = current.first, let lastTok = current.last else { return }
            let text = joinTokens(current)
            defer { current.removeAll() }
            guard !text.isEmpty else { return }
            // 句読点だけの断片は直前の発話にくっつける（認識器が「。」を単独で返すことがある）
            if isPunctuationOnly(text), !segments.isEmpty {
                segments[segments.count - 1].text += text
                segments[segments.count - 1].end = max(segments[segments.count - 1].end, lastTok.end)
                return
            }
            segments.append(TranscriptSegment(
                id: segments.count,
                speaker: currentSpeaker,
                start: first.start,
                end: lastTok.end,
                text: text
            ))
        }

        for (i, token) in tokens.enumerated() {
            let speaker = speakers[i]
            if let prev = current.last {
                let gap = token.start - prev.end
                let prevEndsSentence = prev.text.last.map { options.sentenceEnders.contains($0) } ?? false
                let tooLong = (token.end - current[0].start) > options.maxSegmentSeconds
                let shouldBreak = speaker != currentSpeaker
                    || gap > options.maxPause
                    || prevEndsSentence
                    || (tooLong && prev.text.last == "、")
                    || (token.end - current[0].start) > options.maxSegmentSeconds * 1.5
                if shouldBreak {
                    flush()
                    currentSpeaker = speaker
                }
            } else {
                currentSpeaker = speaker
            }
            current.append(token)
        }
        flush()
        return segments
    }

    // MARK: - Internals

    static func speaker(for token: WordToken, turns: [SpeakerTurn], tolerance: Double) -> String {
        var best: (String, Double)? = nil
        for t in turns {
            let overlap = min(token.end, t.end) - max(token.start, t.start)
            if overlap > 0, overlap > (best?.1 ?? 0) {
                best = (t.speakerID, overlap)
            }
        }
        if let best { return best.0 }
        // 重なりがなければ最寄りの区間
        let mid = (token.start + token.end) / 2
        var nearest: (String, Double)? = nil
        for t in turns {
            let distance = mid < t.start ? t.start - mid : (mid > t.end ? mid - t.end : 0)
            if distance <= tolerance, distance < (nearest?.1 ?? .infinity) {
                nearest = (t.speakerID, distance)
            }
        }
        return nearest?.0 ?? ""
    }

    static func smoothShortRuns(tokens: [WordToken], speakers: inout [String], minRun: Double) {
        guard tokens.count > 2 else { return }
        var i = 0
        while i < speakers.count {
            var j = i
            while j + 1 < speakers.count, speakers[j + 1] == speakers[i] { j += 1 }
            let runLength = tokens[j].end - tokens[i].start
            if runLength < minRun, i > 0, j + 1 < speakers.count, speakers[i - 1] == speakers[j + 1] {
                for k in i...j { speakers[k] = speakers[i - 1] }
            }
            i = j + 1
        }
    }

    /// 日本語はそのまま連結し、英数字同士の間だけ空白を入れる。
    public static func joinTokens(_ tokens: [WordToken]) -> String {
        var out = ""
        for token in tokens {
            let piece = token.text
            if let a = out.last, let b = piece.first, needsSpace(a, b) {
                out.append(" ")
            }
            out += piece
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isPunctuationOnly(_ text: String) -> Bool {
        text.allSatisfy { $0.isPunctuation || $0.isWhitespace || $0.isSymbol }
    }

    static func needsSpace(_ a: Character, _ b: Character) -> Bool {
        func isLatin(_ c: Character) -> Bool {
            c.isASCII && (c.isLetter || c.isNumber)
        }
        return isLatin(a) && isLatin(b)
    }
}

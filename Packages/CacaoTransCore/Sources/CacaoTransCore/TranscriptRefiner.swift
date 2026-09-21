import Foundation

/// 音声認識の生テキストを Claude で校正する（誤変換・句読点・話者ラベルの補正）。
public struct RefinerOptions: Sendable, Equatable {
    /// 1回の問い合わせに入れる文字数の目安。
    public var chunkCharacters: Int = 2500
    /// 同時に投げるチャンク数。
    public var maxConcurrency: Int = 3
    /// 用語集（固有名詞・専門用語・人名など）。改行区切りの自由記述。
    public var glossary: String = ""
    /// 音声の種類や背景（例: 「地域包括ケアに関する3人の会議」）。
    public var context: String = ""
    /// 話者ラベルの補正を Claude に許可するか。
    public var allowSpeakerFix: Bool = true
    /// 「えー」「あの」などのフィラーを軽く取り除くか。
    public var removeFillers: Bool = true

    public init() {}
}

public struct RefineProgress: Sendable {
    public var completedChunks: Int
    public var totalChunks: Int
    public var usage: ClaudeUsage
    public var fraction: Double { totalChunks == 0 ? 1 : Double(completedChunks) / Double(totalChunks) }
}

public actor TranscriptRefiner {
    private let client: ClaudeClient
    private let options: RefinerOptions

    public init(client: ClaudeClient, options: RefinerOptions = RefinerOptions()) {
        self.client = client
        self.options = options
    }

    /// 校正の結果。失敗したチャンクがあっても、成功した分は transcript に反映済み。
    public struct Outcome: Sendable {
        public var transcript: Transcript
        public var totalChunks: Int
        public var failedChunks: Int
        public var usage: ClaudeUsage
        public var lastErrorDescription: String?
        public var succeeded: Bool { failedChunks == 0 }
    }

    /// 全セグメントを校正した Transcript を返す。1つでも失敗すれば throw（成功分は捨てる）。
    public func refine(_ transcript: Transcript,
                       progress: (@Sendable (RefineProgress) -> Void)? = nil) async throws -> Transcript {
        let outcome = await refineTolerant(transcript, progress: progress)
        if outcome.failedChunks > 0 {
            throw ClaudeError.invalidResponse(outcome.lastErrorDescription ?? "校正に失敗しました")
        }
        return outcome.transcript
    }

    /// 失敗したチャンクがあっても止めず、できた分だけ反映して返す。
    public func refineTolerant(_ transcript: Transcript,
                               progress: (@Sendable (RefineProgress) -> Void)? = nil) async -> Outcome {
        let chunks = Self.chunk(transcript.segments, maxCharacters: options.chunkCharacters)
        guard !chunks.isEmpty else {
            return Outcome(transcript: transcript, totalChunks: 0, failedChunks: 0, usage: ClaudeUsage(), lastErrorDescription: nil)
        }
        let knownSpeakers = Set(transcript.speakers)
        let system = makeSystemPrompt(speakers: transcript.speakers)

        var refined: [Int: (speaker: String, text: String)] = [:]
        var completed = 0
        var failed = 0
        var lastError: String?
        var usage = ClaudeUsage()

        await withTaskGroup(of: (Int, [Int: (String, String)], ClaudeUsage, String?).self) { group in
            var next = 0
            func submit(_ index: Int) {
                let before = index > 0 ? Array(chunks[index - 1].suffix(3)) : []
                let after = index + 1 < chunks.count ? Array(chunks[index + 1].prefix(2)) : []
                let chunk = chunks[index]
                let client = self.client
                group.addTask {
                    do {
                        let (parsed, u) = try await Self.process(chunk: chunk, before: before, after: after, system: system, client: client)
                        return (index, parsed, u, nil)
                    } catch {
                        return (index, [:], ClaudeUsage(), error.localizedDescription)
                    }
                }
            }
            while next < min(options.maxConcurrency, chunks.count) {
                submit(next); next += 1
            }
            while let (_, parsed, u, err) = await group.next() {
                if let err {
                    failed += 1
                    lastError = err
                } else {
                    for (id, value) in parsed { refined[id] = value }
                }
                completed += 1
                usage = usage + u
                progress?(RefineProgress(completedChunks: completed, totalChunks: chunks.count, usage: usage))
                if next < chunks.count { submit(next); next += 1 }
            }
        }

        var result = transcript
        for i in result.segments.indices {
            let seg = result.segments[i]
            guard let r = refined[seg.id] else { continue }
            let newText = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newText.isEmpty else { continue }
            result.segments[i].originalText = seg.originalText ?? seg.text
            result.segments[i].text = newText
            if options.allowSpeakerFix, knownSpeakers.contains(r.speaker) {
                result.segments[i].speaker = r.speaker
            }
        }
        return Outcome(transcript: result, totalChunks: chunks.count, failedChunks: failed, usage: usage, lastErrorDescription: lastError)
    }

    /// 1チャンクを校正する。出力が上限で切れたら半分に割って再試行する。
    static func process(chunk: [TranscriptSegment],
                        before: [TranscriptSegment],
                        after: [TranscriptSegment],
                        system: String,
                        client: ClaudeClient) async throws -> ([Int: (String, String)], ClaudeUsage) {
        do {
            let userPrompt = makeUserPrompt(chunk: chunk, before: before, after: after)
            let response = try await client.complete(system: system, user: userPrompt, jsonSchema: outputSchema, maxTokens: 32000)
            return (try parseSegments(response.text), response.usage)
        } catch ClaudeError.truncated where chunk.count >= 2 {
            let mid = chunk.count / 2
            let first = Array(chunk[..<mid])
            let second = Array(chunk[mid...])
            let (a, ua) = try await process(chunk: first, before: before, after: Array(second.prefix(2)), system: system, client: client)
            let (b, ub) = try await process(chunk: second, before: Array(first.suffix(3)), after: after, system: system, client: client)
            return (a.merging(b) { _, new in new }, ua + ub)
        }
    }

    // MARK: - Prompt

    func makeSystemPrompt(speakers: [String]) -> String {
        var lines: [String] = []
        lines.append("あなたは日本語の文字起こしを校正する専門家です。入力は音声認識エンジンの生出力を JSON にしたもので、誤変換（同音異義語の取り違え）や脱字、句読点の欠落があります。")
        lines.append("")
        lines.append("やること:")
        lines.append("- 文脈から明らかな誤変換・誤認識を正しい表記に直す（例: 「機械」→「機会」、「以外」→「意外」など）。")
        lines.append("- 句読点（、。）と疑問符・感嘆符を自然に整える。")
        if options.removeFillers {
            lines.append("- 「えー」「あの」「えっと」「まあ」などの意味を持たないフィラーや、単なる言い直しは軽く取り除く。ただし発言の意味・ニュアンスは変えない。")
        }
        lines.append("- 発言の内容・順序・量を変えない。要約しない。省略しない。言い換えない。敬体・常体もそのまま。")
        lines.append("- 聞き取れなかった箇所を推測で創作しない。不明瞭なら原文のまま残す。")
        if options.allowSpeakerFix {
            lines.append("- speaker は話者分離モデルの推定で、まれに間違っている。会話の流れから明らかに別の話者の発言と分かる場合のみ、既存のラベル（\(speakers.joined(separator: "、"))）のいずれかに直す。確信がなければ変えない。新しいラベルは作らない。")
        } else {
            lines.append("- speaker は変更しない。")
        }
        lines.append("- 入力の全セグメントを、同じ id で必ず返す。セグメントの結合・分割はしない。")
        lines.append("- 「前後の文脈」として渡すセグメントは参考情報であり、出力に含めない。")
        if !options.context.isEmpty {
            lines.append("")
            lines.append("この音声について: \(options.context)")
        }
        let glossary = options.glossary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !glossary.isEmpty {
            lines.append("")
            lines.append("用語集（固有名詞・専門用語はこの表記に統一する）:")
            lines.append(glossary)
        }
        return lines.joined(separator: "\n")
    }

    static func makeUserPrompt(chunk: [TranscriptSegment], before: [TranscriptSegment], after: [TranscriptSegment]) -> String {
        func encode(_ segs: [TranscriptSegment]) -> String {
            let items = segs.map { ["id": $0.id, "speaker": $0.speaker, "text": $0.text] as [String: Any] }
            let data = (try? JSONSerialization.data(withJSONObject: items, options: [.withoutEscapingSlashes])) ?? Data()
            return String(data: data, encoding: .utf8) ?? "[]"
        }
        var parts: [String] = []
        if !before.isEmpty {
            parts.append("前後の文脈（直前、出力しない）:\n\(encode(before))")
        }
        if !after.isEmpty {
            parts.append("前後の文脈（直後、出力しない）:\n\(encode(after))")
        }
        parts.append("校正対象（この全セグメントを同じ id で返す）:\n\(encode(chunk))")
        return parts.joined(separator: "\n\n")
    }

    static let outputSchema = """
    {"type":"object","properties":{"segments":{"type":"array","items":{"type":"object","properties":{"id":{"type":"integer"},"speaker":{"type":"string"},"text":{"type":"string"}},"required":["id","speaker","text"],"additionalProperties":false}}},"required":["segments"],"additionalProperties":false}
    """

    static func parseSegments(_ text: String) throws -> [Int: (String, String)] {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = obj["segments"] as? [[String: Any]] else {
            throw ClaudeError.invalidResponse("構造化出力の JSON を解釈できません")
        }
        var out: [Int: (String, String)] = [:]
        for item in items {
            guard let id = item["id"] as? Int, let t = item["text"] as? String else { continue }
            out[id] = (item["speaker"] as? String ?? "", t)
        }
        return out
    }

    // MARK: - Chunking

    static func chunk(_ segments: [TranscriptSegment], maxCharacters: Int) -> [[TranscriptSegment]] {
        var chunks: [[TranscriptSegment]] = []
        var current: [TranscriptSegment] = []
        var count = 0
        for seg in segments {
            if !current.isEmpty, count + seg.text.count > maxCharacters {
                chunks.append(current)
                current = []
                count = 0
            }
            current.append(seg)
            count += seg.text.count
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}

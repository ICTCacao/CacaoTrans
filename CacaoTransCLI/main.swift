import Foundation
import CacaoTransCore
import CacaoTransEngine

// 検証用 CLI: cacaotrans <音声ファイル> [--no-claude] [--no-diarize] [--format txt|md|docx|srt|csv|json] [--out パス] [--glossary ファイル] [--embed-audio]

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    使い方: cacaotrans <音声ファイル> [オプション]
      --no-claude        Claude 校正を行わない
      --no-diarize       話者分離を行わない
      --format <fmt>     txt | md | docx | srt | csv | json（既定: txt）
      --out <path>       出力先（既定: 標準出力）
      --model <id>       Claude モデル（既定: claude-opus-5）
      --glossary <file>  用語集テキスト
      --context <text>   音声の背景（例: "元兵士への聞き取り。聞き手は山田"）
      --embed-audio      音声を圧縮してプロジェクトに同梱する（--format json のとき）
    API キーは環境変数 ANTHROPIC_API_KEY またはキーチェーン（アプリ設定画面で保存）から読みます。

    """.utf8))
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let first = args.first, !first.hasPrefix("--") else { usage() }
args.removeFirst()
let audioURL = URL(fileURLWithPath: first)

var options = PipelineOptions()
var format: ExportFormat = .text
var outPath: String?
var model = ClaudeConfig.defaultModel

var i = 0
while i < args.count {
    let a = args[i]
    func value() -> String {
        i += 1
        guard i < args.count else { usage() }
        return args[i]
    }
    switch a {
    case "--no-claude": options.useClaude = false
    case "--no-diarize": options.useDiarization = false
    case "--format":
        let v = value()
        switch v {
        case "txt", "text": format = .text
        case "md", "markdown": format = .markdown
        case "docx": format = .docx
        case "srt": format = .srt
        case "csv": format = .csv
        case "json": format = .json
        default: usage()
        }
    case "--out": outPath = value()
    case "--model": model = value()
    case "--glossary":
        options.refiner.glossary = (try? String(contentsOfFile: value(), encoding: .utf8)) ?? ""
    case "--context":
        options.refiner.context = value()
    case "--embed-audio": options.embedAudio = true
    default: usage()
    }
    i += 1
}

if options.useClaude {
    guard let key = KeychainStore.resolveAPIKey() else {
        FileHandle.standardError.write(Data("API キーが見つかりません。ANTHROPIC_API_KEY を設定するか --no-claude を指定してください。\n".utf8))
        exit(1)
    }
    options.claude = ClaudeConfig(apiKey: key, model: model)
}

let semaphore = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0

Task {
    do {
        let started = Date()
        let pipeline = TranscriptionPipeline()
        let lastStage = LastStage()
        let result = try await pipeline.runDetailed(url: audioURL, options: options) { p in
            if lastStage.update(p.stage.rawValue, detail: p.detail, fraction: p.fraction) {
                FileHandle.standardError.write(Data("[\(Int(p.fraction * 100))%] \(p.stage.rawValue) \(p.detail)\n".utf8))
            }
        }
        var transcript = result.transcript
        transcript.context = options.refiner.context.isEmpty ? nil : options.refiner.context
        transcript.glossary = options.refiner.glossary.isEmpty ? nil : options.refiner.glossary
        if let warning = result.warning {
            FileHandle.standardError.write(Data("注意: \(warning)\n".utf8))
        }
        let data = try Exporter.data(for: transcript, format: format)
        if let outPath {
            try data.write(to: URL(fileURLWithPath: outPath))
            FileHandle.standardError.write(Data("書き出し: \(outPath)\n".utf8))
        } else {
            FileHandle.standardOutput.write(data)
        }
        let secs = Int(Date().timeIntervalSince(started))
        FileHandle.standardError.write(Data("完了: \(transcript.segments.count) 発話 / \(transcript.speakers.count) 話者 / \(secs) 秒\n".utf8))
    } catch {
        FileHandle.standardError.write(Data("エラー: \(error.localizedDescription)\n".utf8))
        exitCode = 1
    }
    semaphore.signal()
}

final class LastStage: @unchecked Sendable {
    private let lock = NSLock()
    private var stage = ""
    private var lastPercent = -1
    func update(_ s: String, detail: String, fraction: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let pct = Int(fraction * 100)
        if s != stage || pct / 5 != lastPercent / 5 || !detail.isEmpty && pct != lastPercent {
            stage = s
            lastPercent = pct
            return true
        }
        return false
    }
}

semaphore.wait()
exit(exitCode)

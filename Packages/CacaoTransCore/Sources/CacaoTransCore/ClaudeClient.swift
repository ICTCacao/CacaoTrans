import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Claude API（Messages API）を素の HTTP で呼ぶクライアント。Swift 用公式 SDK はないため URLSession で実装している。
public struct ClaudeConfig: Sendable, Equatable {
    public static let defaultModel = "claude-opus-5"
    public static let availableModels = ["claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5", "claude-opus-4-8", "claude-fable-5-1"]
    public static let effortLevels = ["low", "medium", "high"]

    /// 設定画面向けの短い説明。
    public static func description(for model: String) -> String {
        switch model {
        case "claude-opus-5": return "高精度・標準（入力 $5 / 出力 $25 per 100万トークン）"
        case "claude-sonnet-5": return "バランス型・Opus の約 1/2.5 の費用（$2 / $10）"
        case "claude-haiku-4-5": return "最速・最安（$1 / $5）。思考機能なしで動かします"
        case "claude-opus-4-8": return "前世代の Opus（$5 / $25）"
        case "claude-fable-5-1": return "最上位モデル。費用は Opus の2倍（$10 / $50）"
        default: return ""
        }
    }

    /// 適応型思考と effort に対応するモデルか（Haiku 4.5 は非対応）。
    public static func supportsAdaptiveThinking(_ model: String) -> Bool {
        !model.hasPrefix("claude-haiku")
    }

    /// サーバ側フォールバック（拒否時の自動切り替え）が使えるモデルか。
    public static func supportsFallbacks(_ model: String) -> Bool {
        model.hasPrefix("claude-opus-5") || model.hasPrefix("claude-fable")
    }

    public var apiKey: String
    public var model: String
    public var effort: String
    public var baseURL: URL
    /// 安全上の理由で拒否された場合にサーバ側で別モデルに切り替える（beta）。
    public var useFallbacks: Bool
    public var timeout: TimeInterval

    public init(apiKey: String,
                model: String = ClaudeConfig.defaultModel,
                effort: String = "medium",
                baseURL: URL = URL(string: "https://api.anthropic.com")!,
                useFallbacks: Bool = true,
                timeout: TimeInterval = 600) {
        self.apiKey = apiKey
        self.model = model
        self.effort = effort
        self.baseURL = baseURL
        self.useFallbacks = useFallbacks
        self.timeout = timeout
    }
}

public struct ClaudeUsage: Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    public init(inputTokens: Int = 0, outputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
    public static func + (a: ClaudeUsage, b: ClaudeUsage) -> ClaudeUsage {
        ClaudeUsage(inputTokens: a.inputTokens + b.inputTokens, outputTokens: a.outputTokens + b.outputTokens)
    }
}

public struct ClaudeResponse: Sendable {
    public var text: String
    public var model: String
    public var stopReason: String
    public var usage: ClaudeUsage
}

public enum ClaudeError: Error, LocalizedError, Sendable {
    case missingAPIKey
    case http(status: Int, message: String)
    case refusal(category: String?)
    case truncated
    case invalidResponse(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Claude の API キーが設定されていません。設定画面で入力してください。"
        case .http(let status, let message):
            switch status {
            case 401: return "API キーが無効です（401）。設定画面で確認してください。"
            case 429: return "Claude API のレート制限に達しました（429）。しばらく待って再試行してください。"
            default: return "Claude API エラー（\(status)）: \(message)"
            }
        case .refusal(let category):
            return "Claude が処理を拒否しました" + (category.map { "（\($0)）" } ?? "")
        case .truncated:
            return "Claude の出力が上限に達して途中で切れました。チャンクを小さくして再試行してください。"
        case .invalidResponse(let detail):
            return "Claude の応答を解釈できませんでした: \(detail)"
        case .network(let detail):
            return "通信エラー: \(detail)"
        }
    }
}

public actor ClaudeClient {
    public let config: ClaudeConfig
    private let session: URLSession
    private var fallbacksRejected = false

    public init(config: ClaudeConfig) {
        self.config = config
        let sc = URLSessionConfiguration.default
        sc.timeoutIntervalForRequest = config.timeout
        sc.timeoutIntervalForResource = config.timeout * 2
        sc.waitsForConnectivity = true
        self.session = URLSession(configuration: sc)
    }

    /// 1回の問い合わせ。`jsonSchema` を渡すと構造化出力（JSON）で返させる。
    public func complete(system: String,
                         user: String,
                         jsonSchema: String? = nil,
                         maxTokens: Int = 16000) async throws -> ClaudeResponse {
        guard !config.apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ClaudeError.missingAPIKey
        }

        var attempt = 0
        while true {
            attempt += 1
            let useFallbacks = config.useFallbacks && !fallbacksRejected && ClaudeConfig.supportsFallbacks(config.model)
            let body = try makeBody(system: system, user: user, jsonSchema: jsonSchema, maxTokens: maxTokens, fallbacks: useFallbacks)
            var request = URLRequest(url: config.baseURL.appendingPathComponent("/v1/messages"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            if useFallbacks {
                request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            }
            request.httpBody = body

            let data: Data
            let http: HTTPURLResponse
            do {
                let (d, r) = try await session.data(for: request)
                guard let h = r as? HTTPURLResponse else { throw ClaudeError.invalidResponse("HTTP 応答ではありません") }
                data = d
                http = h
            } catch let e as ClaudeError {
                throw e
            } catch {
                if attempt < 3 {
                    try await Task.sleep(nanoseconds: UInt64(2 * attempt) * 1_000_000_000)
                    continue
                }
                throw ClaudeError.network(error.localizedDescription)
            }

            if http.statusCode == 200 {
                return try parse(data)
            }

            let message = Self.errorMessage(from: data)
            // fallbacks が受け付けられない環境では外して再試行
            if http.statusCode == 400, useFallbacks, message.lowercased().contains("fallback") {
                fallbacksRejected = true
                continue
            }
            if http.statusCode == 429 || http.statusCode >= 500 || http.statusCode == 408 {
                if attempt < 4 {
                    let retryAfter = http.value(forHTTPHeaderField: "retry-after").flatMap(Double.init) ?? Double(5 * attempt)
                    try await Task.sleep(nanoseconds: UInt64(min(retryAfter, 60)) * 1_000_000_000)
                    continue
                }
            }
            throw ClaudeError.http(status: http.statusCode, message: message)
        }
    }

    // MARK: - Request / response

    private func makeBody(system: String, user: String, jsonSchema: String?, maxTokens: Int, fallbacks: Bool) throws -> Data {
        let adaptive = ClaudeConfig.supportsAdaptiveThinking(config.model)
        var outputConfig: [String: Any] = [:]
        if adaptive { outputConfig["effort"] = config.effort }
        if let jsonSchema {
            guard let schemaData = jsonSchema.data(using: .utf8),
                  let schema = try JSONSerialization.jsonObject(with: schemaData) as? [String: Any] else {
                throw ClaudeError.invalidResponse("JSON スキーマが不正です")
            }
            outputConfig["format"] = ["type": "json_schema", "schema": schema]
        }
        var body: [String: Any] = [
            "model": config.model,
            "max_tokens": maxTokens,
            "system": system,
            "output_config": outputConfig,
            "messages": [["role": "user", "content": user]],
        ]
        if adaptive {
            body["thinking"] = ["type": "adaptive"]
        }
        if fallbacks {
            body["fallbacks"] = "default"
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    private func parse(_ data: Data) throws -> ClaudeResponse {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeError.invalidResponse("JSON ではありません")
        }
        let stopReason = obj["stop_reason"] as? String ?? ""
        if stopReason == "refusal" {
            let category = (obj["stop_details"] as? [String: Any])?["category"] as? String
            throw ClaudeError.refusal(category: category)
        }
        if stopReason == "max_tokens" {
            throw ClaudeError.truncated
        }
        let content = obj["content"] as? [[String: Any]] ?? []
        let text = content.compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }.joined()
        let usageObj = obj["usage"] as? [String: Any] ?? [:]
        let usage = ClaudeUsage(inputTokens: usageObj["input_tokens"] as? Int ?? 0,
                                outputTokens: usageObj["output_tokens"] as? Int ?? 0)
        return ClaudeResponse(text: text,
                              model: obj["model"] as? String ?? config.model,
                              stopReason: stopReason,
                              usage: usage)
    }

    private static func errorMessage(from data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? [String: Any],
           let msg = err["message"] as? String {
            return msg
        }
        return String(data: data, encoding: .utf8) ?? "(本文なし)"
    }
}

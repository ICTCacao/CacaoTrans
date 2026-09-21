import Foundation

public struct FindReplaceOptions: Sendable, Equatable {
    public var caseSensitive: Bool = false
    public var useRegex: Bool = false

    public init(caseSensitive: Bool = false, useRegex: Bool = false) {
        self.caseSensitive = caseSensitive
        self.useRegex = useRegex
    }
}

/// 文字起こし全体に対する一括検索・置換。
public enum FindReplace {
    public struct Match: Sendable, Equatable {
        public var segmentID: Int
        public var range: Range<Int>  // UTF-16 offset
    }

    public static func regex(for query: String, options: FindReplaceOptions) throws -> NSRegularExpression {
        let pattern = options.useRegex ? query : NSRegularExpression.escapedPattern(for: query)
        var flags: NSRegularExpression.Options = []
        if !options.caseSensitive { flags.insert(.caseInsensitive) }
        return try NSRegularExpression(pattern: pattern, options: flags)
    }

    public static func matches(in transcript: Transcript, query: String, options: FindReplaceOptions = .init()) -> [Match] {
        guard !query.isEmpty, let re = try? regex(for: query, options: options) else { return [] }
        var out: [Match] = []
        for seg in transcript.segments {
            let ns = seg.text as NSString
            for m in re.matches(in: seg.text, range: NSRange(location: 0, length: ns.length)) {
                out.append(Match(segmentID: seg.id, range: m.range.location..<(m.range.location + m.range.length)))
            }
        }
        return out
    }

    public static func count(in transcript: Transcript, query: String, options: FindReplaceOptions = .init()) -> Int {
        matches(in: transcript, query: query, options: options).count
    }

    /// 置換を適用し、置換件数を返す。
    @discardableResult
    public static func apply(to transcript: inout Transcript, query: String, replacement: String, options: FindReplaceOptions = .init()) -> Int {
        guard !query.isEmpty, let re = try? regex(for: query, options: options) else { return 0 }
        let template = options.useRegex ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
        var total = 0
        for i in transcript.segments.indices {
            let text = transcript.segments[i].text
            let ns = text as NSString
            let range = NSRange(location: 0, length: ns.length)
            let n = re.numberOfMatches(in: text, range: range)
            guard n > 0 else { continue }
            transcript.segments[i].text = re.stringByReplacingMatches(in: text, range: range, withTemplate: template)
            total += n
        }
        return total
    }

    /// 検証用: パターンが有効か。
    public static func validate(query: String, options: FindReplaceOptions) -> String? {
        guard options.useRegex, !query.isEmpty else { return nil }
        do { _ = try regex(for: query, options: options); return nil } catch { return "正規表現が不正です" }
    }
}

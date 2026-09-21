import Foundation

public enum ExportFormat: String, CaseIterable, Sendable, Identifiable {
    case text, markdown, docx, srt, csv, json

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .text: return "テキスト (.txt)"
        case .markdown: return "Markdown (.md)"
        case .docx: return "Word (.docx)"
        case .srt: return "字幕 (.srt)"
        case .csv: return "CSV (.csv)"
        case .json: return "プロジェクト (.\(Transcript.projectFileExtension))"
        }
    }

    public var fileExtension: String {
        switch self {
        case .text: return "txt"
        case .markdown: return "md"
        case .docx: return "docx"
        case .srt: return "srt"
        case .csv: return "csv"
        case .json: return Transcript.projectFileExtension
        }
    }
}

public struct ExportOptions: Sendable, Equatable {
    public var includeTimestamps: Bool = true
    public var includeSpeakers: Bool = true
    /// 同じ話者の連続発話を1段落にまとめる。
    public var mergeConsecutiveSpeakers: Bool = true

    public init(includeTimestamps: Bool = true, includeSpeakers: Bool = true, mergeConsecutiveSpeakers: Bool = true) {
        self.includeTimestamps = includeTimestamps
        self.includeSpeakers = includeSpeakers
        self.mergeConsecutiveSpeakers = mergeConsecutiveSpeakers
    }
}

public enum Exporter {
    public static func data(for transcript: Transcript, format: ExportFormat, options: ExportOptions = .init()) throws -> Data {
        var transcript = transcript
        if format != .json {
            transcript.segments.removeAll { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        switch format {
        case .text: return Data(text(transcript, options: options).utf8)
        case .markdown: return Data(markdown(transcript, options: options).utf8)
        case .srt: return Data(srt(transcript, options: options).utf8)
        case .csv: return Data(csv(transcript).utf8)
        case .json: return try transcript.projectData()
        case .docx: return try DocxWriter.make(transcript, options: options)
        }
    }

    // MARK: - Paragraph model shared by text/markdown/docx

    struct Paragraph {
        var speaker: String
        var start: Double
        var end: Double
        var text: String
    }

    static func paragraphs(_ transcript: Transcript, options: ExportOptions) -> [Paragraph] {
        var out: [Paragraph] = []
        for seg in transcript.segments {
            let name = transcript.displayName(for: seg.speaker)
            if options.mergeConsecutiveSpeakers, let last = out.last, last.speaker == name {
                out[out.count - 1].text += seg.text
                out[out.count - 1].end = seg.end
            } else {
                out.append(Paragraph(speaker: name, start: seg.start, end: seg.end, text: seg.text))
            }
        }
        return out
    }

    static func header(_ p: Paragraph, options: ExportOptions) -> String {
        var parts: [String] = []
        if options.includeTimestamps { parts.append("[\(Transcript.formatTime(p.start, alwaysHours: true))]") }
        if options.includeSpeakers { parts.append(p.speaker + ":") }
        return parts.joined(separator: " ")
    }

    public static func text(_ transcript: Transcript, options: ExportOptions = .init()) -> String {
        paragraphs(transcript, options: options).map { p in
            let h = header(p, options: options)
            return h.isEmpty ? p.text : "\(h) \(p.text)"
        }.joined(separator: "\n\n") + "\n"
    }

    public static func markdown(_ transcript: Transcript, options: ExportOptions = .init()) -> String {
        var lines: [String] = []
        lines.append("# \(transcript.sourceFileName)")
        lines.append("")
        lines.append("- 長さ: \(Transcript.formatTime(transcript.duration, alwaysHours: true))")
        lines.append("- 話者: \(transcript.speakers.map { transcript.displayName(for: $0) }.joined(separator: "、"))")
        lines.append("")
        for p in paragraphs(transcript, options: options) {
            var h: [String] = []
            if options.includeSpeakers { h.append("**\(p.speaker)**") }
            if options.includeTimestamps { h.append("(\(Transcript.formatTime(p.start, alwaysHours: true)))") }
            let head = h.joined(separator: " ")
            lines.append(head.isEmpty ? p.text : "\(head)  \n\(p.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    public static func srt(_ transcript: Transcript, options: ExportOptions = .init()) -> String {
        func ts(_ s: Double) -> String {
            let ms = Int((s * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
        }
        var out: [String] = []
        for (i, seg) in transcript.segments.enumerated() {
            let end = max(seg.end, seg.start + 0.5)
            let label = options.includeSpeakers ? "\(transcript.displayName(for: seg.speaker)): " : ""
            out.append("\(i + 1)\n\(ts(seg.start)) --> \(ts(end))\n\(label)\(seg.text)\n")
        }
        return out.joined(separator: "\n")
    }

    public static func csv(_ transcript: Transcript) -> String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var lines = ["id,start,end,speaker,text"]
        for seg in transcript.segments {
            lines.append([
                String(seg.id),
                String(format: "%.2f", seg.start),
                String(format: "%.2f", seg.end),
                q(transcript.displayName(for: seg.speaker)),
                q(seg.text),
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}

// MARK: - DOCX

/// 依存ライブラリなしで最小構成の .docx を作る（ZIP は無圧縮）。
enum DocxWriter {
    static func make(_ transcript: Transcript, options: ExportOptions) throws -> Data {
        var body = ""
        body += paragraphXML(runs: [(text: transcript.sourceFileName, bold: true, size: 28)])
        body += paragraphXML(runs: [(text: "長さ \(Transcript.formatTime(transcript.duration, alwaysHours: true)) / 話者 \(transcript.speakers.map { transcript.displayName(for: $0) }.joined(separator: "、"))", bold: false, size: 20)])
        for p in Exporter.paragraphs(transcript, options: options) {
            var runs: [(text: String, bold: Bool, size: Int)] = []
            let head = Exporter.header(p, options: options)
            if !head.isEmpty { runs.append((text: head + " ", bold: true, size: 21)) }
            runs.append((text: p.text, bold: false, size: 21))
            body += paragraphXML(runs: runs)
        }
        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\(body)<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1418" w:right="1418" w:bottom="1418" w:left="1418" w:header="709" w:footer="709" w:gutter="0"/></w:sectPr></w:body></w:document>
        """
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/></Types>
        """
        let rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
        """
        let docRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
        """
        let styles = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Hiragino Sans" w:hAnsi="Hiragino Sans" w:eastAsia="Hiragino Sans"/><w:sz w:val="21"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="300" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults></w:styles>
        """
        var zip = ZipWriter()
        zip.add(path: "[Content_Types].xml", data: Data(contentTypes.utf8))
        zip.add(path: "_rels/.rels", data: Data(rels.utf8))
        zip.add(path: "word/document.xml", data: Data(document.utf8))
        zip.add(path: "word/_rels/document.xml.rels", data: Data(docRels.utf8))
        zip.add(path: "word/styles.xml", data: Data(styles.utf8))
        return zip.finish()
    }

    static func paragraphXML(runs: [(text: String, bold: Bool, size: Int)]) -> String {
        var xml = "<w:p>"
        for r in runs {
            xml += "<w:r><w:rPr>"
            if r.bold { xml += "<w:b/>" }
            xml += "<w:sz w:val=\"\(r.size)\"/></w:rPr>"
            xml += "<w:t xml:space=\"preserve\">\(escape(r.text))</w:t></w:r>"
        }
        xml += "</w:p>"
        return xml
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// 無圧縮（stored）ZIP の書き出し。docx 用途に十分な最小実装。
struct ZipWriter {
    private var body = Data()
    private var central = Data()
    private var entries = 0

    mutating func add(path: String, data: Data) {
        let name = Data(path.utf8)
        let crc = CRC32.checksum(data)
        let offset = UInt32(body.count)
        let (dosTime, dosDate) = ZipWriter.dosDateTime()

        var local = Data()
        local.append(le32(0x04034b50))
        local.append(le16(20))            // version needed
        local.append(le16(0x0800))        // flags: UTF-8 names
        local.append(le16(0))             // method: stored
        local.append(le16(dosTime))
        local.append(le16(dosDate))
        local.append(le32(crc))
        local.append(le32(UInt32(data.count)))
        local.append(le32(UInt32(data.count)))
        local.append(le16(UInt16(name.count)))
        local.append(le16(0))
        local.append(name)
        local.append(data)
        body.append(local)

        var c = Data()
        c.append(le32(0x02014b50))
        c.append(le16(20))                // version made by
        c.append(le16(20))                // version needed
        c.append(le16(0x0800))
        c.append(le16(0))
        c.append(le16(dosTime))
        c.append(le16(dosDate))
        c.append(le32(crc))
        c.append(le32(UInt32(data.count)))
        c.append(le32(UInt32(data.count)))
        c.append(le16(UInt16(name.count)))
        c.append(le16(0))                 // extra len
        c.append(le16(0))                 // comment len
        c.append(le16(0))                 // disk
        c.append(le16(0))                 // internal attrs
        c.append(le32(0))                 // external attrs
        c.append(le32(offset))
        c.append(name)
        central.append(c)
        entries += 1
    }

    func finish() -> Data {
        var out = body
        out.append(central)
        out.append(le32(0x06054b50))
        out.append(le16(0))
        out.append(le16(0))
        out.append(le16(UInt16(entries)))
        out.append(le16(UInt16(entries)))
        out.append(le32(UInt32(central.count)))
        out.append(le32(UInt32(body.count)))
        out.append(le16(0))
        return out
    }

    private func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    static func dosDateTime(_ date: Date = Date()) -> (UInt16, UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents(in: TimeZone.current, from: date)
        let year = max(1980, c.year ?? 1980)
        let time = UInt16(((c.hour ?? 0) << 11) | ((c.minute ?? 0) << 5) | ((c.second ?? 0) / 2))
        let day = UInt16(((year - 1980) << 9) | ((c.month ?? 1) << 5) | (c.day ?? 1))
        return (time, day)
    }
}

enum CRC32 {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}

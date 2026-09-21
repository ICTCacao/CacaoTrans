import Testing
import Foundation
@testable import CacaoTransCore

@Suite struct SpeakerAssignerTests {
    @Test func assignsSpeakersAndSplitsOnChange() {
        let tokens = [
            WordToken(text: "こんにちは。", start: 0.0, end: 1.0),
            WordToken(text: "今日は", start: 1.1, end: 1.6),
            WordToken(text: "よろしく", start: 1.6, end: 2.2),
            WordToken(text: "お願いします。", start: 2.2, end: 3.0),
            WordToken(text: "はい、", start: 3.5, end: 4.0),
            WordToken(text: "こちらこそ。", start: 4.0, end: 5.0),
        ]
        let turns = [
            SpeakerTurn(speakerID: "B", start: 0.0, end: 3.2),
            SpeakerTurn(speakerID: "A", start: 3.3, end: 5.5),
        ]
        let segs = SpeakerAssigner.makeSegments(tokens: tokens, turns: turns)
        #expect(segs.count == 3)
        #expect(segs[0].speaker == "話者1")
        #expect(segs[0].text == "こんにちは。")
        #expect(segs[1].text == "今日はよろしくお願いします。")
        #expect(segs[2].speaker == "話者2")
        #expect(segs[2].text == "はい、こちらこそ。")
    }

    @Test func lonePunctuationJoinsPreviousSegment() {
        let tokens = [
            WordToken(text: "はい", start: 0.0, end: 0.5),
            WordToken(text: "。", start: 3.0, end: 3.1),   // 長い間の後に句点だけ
            WordToken(text: "次です。", start: 3.5, end: 4.5),
        ]
        let segs = SpeakerAssigner.makeSegments(tokens: tokens, turns: [SpeakerTurn(speakerID: "A", start: 0, end: 5)])
        #expect(segs.count == 2)
        #expect(segs[0].text == "はい。")
        #expect(segs[1].text == "次です。")
    }

    @Test func joinsLatinWithSpaces() {
        let t = [WordToken(text: "Hello", start: 0, end: 1), WordToken(text: "world", start: 1, end: 2), WordToken(text: "です", start: 2, end: 3)]
        #expect(SpeakerAssigner.joinTokens(t) == "Hello worldです")
    }

    @Test func smoothsShortFlips() {
        let tokens = (0..<6).map { WordToken(text: "あ", start: Double($0), end: Double($0) + 0.9) }
        let turns = [
            SpeakerTurn(speakerID: "X", start: 0, end: 2.95),
            SpeakerTurn(speakerID: "Y", start: 3.0, end: 3.2),   // 0.2秒だけ Y
            SpeakerTurn(speakerID: "X", start: 3.3, end: 6),
        ]
        let segs = SpeakerAssigner.makeSegments(tokens: tokens, turns: turns)
        #expect(segs.allSatisfy { $0.speaker == "話者1" })
    }
}

@Suite struct FindReplaceTests {
    func sample() -> Transcript {
        Transcript(sourceFileName: "a.m4a", duration: 10, segments: [
            TranscriptSegment(id: 0, speaker: "話者1", start: 0, end: 1, text: "機械があれば参加します。"),
            TranscriptSegment(id: 1, speaker: "話者2", start: 1, end: 2, text: "機械を逃さないように。"),
        ])
    }

    @Test func countsAndReplaces() {
        var t = sample()
        #expect(FindReplace.count(in: t, query: "機械") == 2)
        let n = FindReplace.apply(to: &t, query: "機械", replacement: "機会")
        #expect(n == 2)
        #expect(t.segments[0].text == "機会があれば参加します。")
    }

    @Test func regexReplace() {
        var t = sample()
        let n = FindReplace.apply(to: &t, query: "機械(が|を)", replacement: "機会$1", options: .init(useRegex: true))
        #expect(n == 2)
        #expect(t.segments[1].text == "機会を逃さないように。")
    }

    @Test func invalidRegexIsReported() {
        #expect(FindReplace.validate(query: "(", options: .init(useRegex: true)) != nil)
    }
}

@Suite struct ExporterTests {
    func sample() -> Transcript {
        var t = Transcript(sourceFileName: "会議.m4a", duration: 65, segments: [
            TranscriptSegment(id: 0, speaker: "話者1", start: 0, end: 2, text: "始めます。"),
            TranscriptSegment(id: 1, speaker: "話者1", start: 2, end: 4, text: "議題は三つ。"),
            TranscriptSegment(id: 2, speaker: "話者2", start: 5, end: 7, text: "了解。"),
        ])
        t.speakerNames["話者1"] = "司会"
        return t
    }

    @Test func textMergesConsecutiveSpeakers() {
        let s = Exporter.text(sample())
        #expect(s.contains("[0:00:00] 司会: 始めます。議題は三つ。"))
        #expect(s.contains("[0:00:05] 話者2: 了解。"))
    }

    @Test func srtHasTimecodes() {
        let s = Exporter.srt(sample())
        #expect(s.contains("00:00:00,000 --> 00:00:02,000"))
        #expect(s.contains("司会: 始めます。"))
    }

    @Test func docxIsValidZip() throws {
        let data = try Exporter.data(for: sample(), format: .docx)
        #expect(data.count > 500)
        #expect(data[0] == 0x50 && data[1] == 0x4b)
        // 終端レコード
        let tail = data.suffix(22)
        #expect(tail[tail.startIndex] == 0x50 && tail[tail.startIndex + 1] == 0x4b && tail[tail.startIndex + 2] == 0x05 && tail[tail.startIndex + 3] == 0x06)
    }

    @Test func projectRoundTrip() throws {
        let t = sample()
        let data = try t.projectData()
        let back = try Transcript.fromProjectData(data)
        #expect(back.segments == t.segments)
        #expect(back.speakerNames == t.speakerNames)
    }

    @Test func crc32KnownValue() {
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF43926)
    }
}

@Suite struct RefinerTests {
    @Test func chunksByCharacterBudget() {
        let segs = (0..<10).map { TranscriptSegment(id: $0, speaker: "話者1", start: 0, end: 1, text: String(repeating: "あ", count: 100)) }
        let chunks = TranscriptRefiner.chunk(segs, maxCharacters: 250)
        #expect(chunks.count == 5)
        #expect(chunks.allSatisfy { $0.count == 2 })
    }

    @Test func parsesStructuredOutput() throws {
        let json = #"{"segments":[{"id":3,"speaker":"話者2","text":"機会です。"}]}"#
        let parsed = try TranscriptRefiner.parseSegments(json)
        #expect(parsed[3]?.1 == "機会です。")
        #expect(parsed[3]?.0 == "話者2")
    }
}

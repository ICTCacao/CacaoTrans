import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CacaoTransCore
#if CLAUDE_TRANS
import CacaoTransEngine
#endif

/// 設定（UserDefaults に保存）。API キーだけはキーチェーン。
struct AppSettings: Equatable {
    var model = ClaudeConfig.defaultModel
    var effort = "medium"
    var useClaude = true
    var useDiarization = true
    var removeFillers = true
    var allowSpeakerFix = true
    var chunkCharacters = 2500
    var glossary = ""
    var context = ""
    var exportTimestamps = true
    var exportSpeakers = true
    var exportMerge = true
    /// 文字起こし後に音声を圧縮してプロジェクトに同梱する。
    var embedAudio = true

    private static let key = "CacaoTrans.settings"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(Stored.self, from: data) else { return AppSettings() }
        var out = AppSettings()
        out.model = s.model; out.effort = s.effort; out.useClaude = s.useClaude; out.useDiarization = s.useDiarization
        out.removeFillers = s.removeFillers; out.allowSpeakerFix = s.allowSpeakerFix; out.chunkCharacters = s.chunkCharacters
        out.glossary = s.glossary; out.context = s.context
        out.exportTimestamps = s.exportTimestamps; out.exportSpeakers = s.exportSpeakers; out.exportMerge = s.exportMerge
        out.embedAudio = s.embedAudio ?? true
        return out
    }

    func save() {
        let s = Stored(model: model, effort: effort, useClaude: useClaude, useDiarization: useDiarization,
                       removeFillers: removeFillers, allowSpeakerFix: allowSpeakerFix, chunkCharacters: chunkCharacters,
                       glossary: glossary, context: context,
                       exportTimestamps: exportTimestamps, exportSpeakers: exportSpeakers, exportMerge: exportMerge,
                       embedAudio: embedAudio)
        if let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    private struct Stored: Codable {
        var model, effort: String
        var useClaude, useDiarization, removeFillers, allowSpeakerFix: Bool
        var chunkCharacters: Int
        var glossary, context: String
        var exportTimestamps, exportSpeakers, exportMerge: Bool
        // 1.1.0 以前の保存データにはない
        var embedAudio: Bool?
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var audioURL: URL?
    @Published var projectURL: URL?
    @Published var transcript: Transcript? {
        didSet { if transcript != nil { isDirty = true } }
    }
    @Published var isDirty = false

    @Published var isProcessing = false
    #if CLAUDE_TRANS
    @Published var progress: PipelineProgress?
    #endif
    @Published var errorMessage: String?
    /// 処理は完了したが注意が必要なとき（Claude 校正の一部失敗など）。
    @Published var warningMessage: String?

    @Published var showFindReplace = false
    @Published var showExport = false
    @Published var findQuery = ""
    @Published var replaceText = ""
    @Published var findOptions = FindReplaceOptions()
    @Published var showOnlyMatches = false
    @Published var lastReplaceMessage: String?
    /// 本文を編集中（フォーカス中）の発話。分割・統合のキーボード操作の対象で、F8 の再生対象にもなる。
    @Published var focusedSegmentID: Int? {
        didSet {
            guard let id = focusedSegmentID, id != oldValue,
                  let seg = transcript?.segments.first(where: { $0.id == id }) else { return }
            playback.cue(segment: seg)
        }
    }
    /// 複数選択中の発話（一括でつなげる・話者変更・削除の対象）。
    /// 1件だけ選んだとき（↑↓ キーでの移動を含む）はその発話を再生対象にする。
    @Published var selectedSegmentIDs: Set<Int> = [] {
        didSet {
            guard !selectingFromPlayback, selectedSegmentIDs.count == 1, selectedSegmentIDs != oldValue,
                  let id = selectedSegmentIDs.first else { return }
            // List の選択処理（AppKit のレイアウト中）から抜けてから再生側を更新する
            Task { @MainActor [weak self] in
                guard let self, self.selectedSegmentIDs == [id],
                      let seg = self.transcript?.segments.first(where: { $0.id == id }) else { return }
                self.playback.cue(segment: seg)
            }
        }
    }
    /// 再生側から選択を合わせている最中（このときは再生対象を付け替えない）。
    private var selectingFromPlayback = false
    /// 「この音声について」シートの表示モード。
    @Published var infoSheet: InfoSheetMode?
    /// 文字起こし開始前にシートで入力した背景・用語集。
    private var pendingContext: String?
    private var pendingGlossary: String?

    enum InfoSheetMode: Int, Identifiable {
        case transcribe, refine, edit
        var id: Int { rawValue }
    }

    /// シートの初期値。プロジェクトに入っていればそれ、なければ設定画面の初期値。
    var infoDefaults: (context: String, glossary: String) {
        let c = transcript?.context ?? pendingContext ?? settings.context
        let g = transcript?.glossary ?? pendingGlossary ?? settings.glossary
        return (c, g)
    }

    /// シートの確定。モードに応じて保存・開始する。
    func confirmProjectInfo(context: String, glossary: String) {
        let c = context.trimmingCharacters(in: .whitespacesAndNewlines)
        let g = glossary.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingContext = c
        pendingGlossary = g
        if var t = transcript {
            t.context = c
            t.glossary = g
            transcript = t
        }
        let mode = infoSheet
        infoSheet = nil
        #if CLAUDE_TRANS
        switch mode {
        case .transcribe: startTranscription()
        case .refine: refineOnly()
        default: break
        }
        #endif
    }

    @Published var settings = AppSettings.load() {
        didSet { settings.save() }
    }
    #if CLAUDE_TRANS
    @Published var apiKeyPresent = KeychainStore.loadAPIKey() != nil
    #else
    let apiKeyPresent = false
    #endif

    let playback = PlaybackController()
    let audioFolder = AudioFolderStore()
    /// 同梱音声を再生用に書き出した一時ファイル（audioURL がこれなら同梱音声で再生している）。
    @Published private(set) var embeddedTempURL: URL?

    var isUsingEmbeddedAudio: Bool { embeddedTempURL != nil && audioURL == embeddedTempURL }

    /// サイドバー用の「音声」欄の文言（短く。詳細は audioSourceHelp）。
    var audioSourceDescription: String {
        guard let t = transcript else { return "" }
        if let e = t.embeddedAudio {
            let size = ByteCountFormatter.string(fromByteCount: Int64(e.byteCount), countStyle: .file)
            return audioURL != nil && !isUsingEmbeddedAudio ? "同梱 \(size)・元ファイル再生" : "同梱 \(size)"
        }
        return audioURL == nil ? "同梱なし・未接続" : "同梱なし・元ファイル"
    }

    var audioSourceHelp: String {
        guard let t = transcript else { return "" }
        var lines: [String] = []
        if let e = t.embeddedAudio {
            lines.append("プロジェクトに音声を同梱しています" + (e.codecDescription.map { "（\($0)）" } ?? ""))
        } else {
            lines.append("音声はプロジェクトに同梱されていません")
        }
        if let audioURL {
            lines.append(isUsingEmbeddedAudio ? "再生: 同梱した音声" : "再生: \(audioURL.path)")
        } else {
            lines.append("再生: 音声が見つかりません")
        }
        return lines.joined(separator: "\n")
    }

    private var undoStack: [Transcript] = []
    private var redoStack: [Transcript] = []
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    private var runningTask: Task<Void, Never>?

    init() {
        playback.setSegmentsProvider { [weak self] in self?.transcript?.segments ?? [] }
        installKeyMonitor()
        // F8 などで再生を始めた発話を選択状態にする（本文を編集中・複数選択中は触らない）
        playback.onStartSegment = { [weak self] id in
            guard let self, self.focusedSegmentID == nil, self.selectedSegmentIDs.count <= 1,
                  self.selectedSegmentIDs != [id] else { return }
            self.selectingFromPlayback = true
            self.selectedSegmentIDs = [id]
            self.selectingFromPlayback = false
        }
    }

    /// 再生のキー操作。リストにキーボードフォーカスがなくても効くよう、SwiftUI の onKeyPress ではなくアプリ全体のキー入力で拾う。
    /// - F7 / F9: 前／次の発話を再生（本文を入力中でも効く。F8 の再生／一時停止はメニューのショートカット）
    /// - Space: 発話を1件選んでいる（文字を入力中ではない）とき、その発話を頭から再生する。何度でも聞き直せる
    private func installKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function]).isEmpty,
                  let window = event.window, window.attachedSheet == nil else { return event }
            switch Int(event.keyCode) {
            case 98 where self.playback.isLoaded:   // F7
                self.playback.playPrevious()
                return nil
            case 101 where self.playback.isLoaded:  // F9
                self.playback.playNext()
                return nil
            case 49 where !(window.firstResponder is NSText) && self.replaySelectedSegment():  // Space
                return nil
            default:
                return event
            }
        }
    }

    /// 1件だけ選んでいる発話を頭から再生する。再生できたら true。
    private func replaySelectedSegment() -> Bool {
        guard playback.isLoaded, selectedSegmentIDs.count == 1, let id = selectedSegmentIDs.first,
              let seg = transcript?.segments.first(where: { $0.id == id }) else { return false }
        playback.replay(segment: seg)
        return true
    }

    // MARK: - Derived

    var matchCount: Int {
        guard let transcript, !findQuery.isEmpty else { return 0 }
        return FindReplace.count(in: transcript, query: findQuery, options: findOptions)
    }

    var findValidationMessage: String? {
        FindReplace.validate(query: findQuery, options: findOptions)
    }

    /// 発話 ID → 本文中の一致範囲（UTF-16 オフセット）。一覧の描画で1回だけ計算して各行に配る。
    var matchRangesBySegment: [Int: [Range<Int>]] {
        guard let transcript, !findQuery.isEmpty, findValidationMessage == nil else { return [:] }
        var out: [Int: [Range<Int>]] = [:]
        for m in FindReplace.matches(in: transcript, query: findQuery, options: findOptions) {
            out[m.segmentID, default: []].append(m.range)
        }
        return out
    }

    func clearFind() {
        findQuery = ""
        replaceText = ""
        showOnlyMatches = false
    }

    // MARK: - File open

    #if CLAUDE_TRANS
    func openAudio() {
        let panel = NSOpenPanel()
        panel.title = "音声ファイルを選択"
        panel.allowedContentTypes = [.audio, .mpeg4Audio, .mp3, .wav, .aiff, .movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard AudioFileTypes.isSupported(url) else {
            errorMessage = "対応していないファイル形式です: \(url.lastPathComponent)"
            return
        }
        projectURL = nil
        transcript = nil
        isDirty = false
        undoStack.removeAll()
        pendingContext = nil
        pendingGlossary = nil
        attachAudio(url, securityScoped: false)
        infoSheet = .transcribe
    }

    /// 同じ音声で文字起こしをやり直す（シートで背景を確認してから）。
    func requestTranscription() {
        guard audioURL != nil, !isProcessing else { return }
        infoSheet = .transcribe
    }

    /// Claude 校正だけやり直す（シートで背景を確認してから）。
    func requestRefine() {
        guard transcript != nil, !isProcessing else { return }
        infoSheet = .refine
    }
    #endif

    /// 再生用に音声ファイルを結び付ける。
    func attachAudio(_ url: URL, securityScoped: Bool) {
        if let tmp = embeddedTempURL, tmp != url {
            playback.unload()
            discardEmbeddedTemp()
        }
        audioURL = url
        do {
            try playback.load(url: url, securityScoped: securityScoped)
        } catch {
            playback.unload()
            errorMessage = "音声を再生用に読み込めませんでした: \(error.localizedDescription)"
        }
    }

    /// プロジェクトに音声ファイルへの参照を書き込む。
    private func storeAudioReference(_ url: URL, into transcript: inout Transcript) {
        transcript.sourceFilePath = url.path
        transcript.sourceBookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// 同梱音声を一時ファイルに書き出す（AVAudioPlayer と再文字起こしが URL を要るため）。
    private func materializeEmbeddedAudio(_ audio: EmbeddedAudio, sourceFileName: String) -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmbeddedAudio", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        var base = (sourceFileName as NSString).deletingPathExtension
        if base.isEmpty { base = "audio" }
        let url = dir.appendingPathComponent(base + "." + audio.fileExtension)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try audio.data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    private func discardEmbeddedTemp() {
        guard let url = embeddedTempURL else { return }
        embeddedTempURL = nil
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// 保存済みプロジェクトから音声を探して結び付ける。元ファイル → 同梱音声 → 音声フォルダ の順。
    private func restoreAudio(from transcript: Transcript) {
        playback.unload()
        discardEmbeddedTemp()
        audioURL = nil
        if let data = transcript.sourceBookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: url.path) {
                attachAudio(url, securityScoped: true)
                return
            }
        }
        if let path = transcript.sourceFilePath, FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            if (try? AVAudioPlayerProbe.canOpen(url)) == true {
                attachAudio(url, securityScoped: false)
                return
            }
        }
        if let embedded = transcript.embeddedAudio,
           let url = materializeEmbeddedAudio(embedded, sourceFileName: transcript.sourceFileName) {
            embeddedTempURL = url
            attachAudio(url, securityScoped: false)
            return
        }
        // 音声フォルダ（既定: 書類/CacaoTrans）から同名ファイルを探す
        let candidates = [transcript.sourceFileName,
                          transcript.sourceFilePath.map { ($0 as NSString).lastPathComponent } ?? ""]
        for name in candidates {
            if let url = audioFolder.locate(fileNamed: name), (try? AVAudioPlayerProbe.canOpen(url)) == true {
                attachAudio(url, securityScoped: false)
                return
            }
        }
    }

    /// 音声フォルダを選び直し、開いているプロジェクトの音声を探し直す。
    func chooseAudioFolder() {
        guard audioFolder.choose() else { return }
        if let t = transcript, !playback.isLoaded {
            restoreAudio(from: t)
            if playback.isLoaded {
                lastReplaceMessage = "音声フォルダから「\(t.sourceFileName)」を見つけました"
            } else {
                lastReplaceMessage = "音声フォルダに「\(t.sourceFileName)」が見つかりません。「音声ファイルを指定…」で選んでください"
            }
        }
    }

    /// 「音声ファイルを指定…」で再リンクする。
    func relinkAudio() {
        let panel = NSOpenPanel()
        panel.title = "この文字起こしの元になった音声ファイルを選択"
        panel.allowedContentTypes = [.audio, .mpeg4Audio, .mp3, .wav, .aiff, .movie]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        attachAudio(url, securityScoped: false)
        if var t = transcript {
            storeAudioReference(url, into: &t)
            transcript = t
        }
    }

    static var projectContentTypes: [UTType] {
        Transcript.allProjectFileExtensions.compactMap { UTType(filenameExtension: $0) } + [.json]
    }

    func openProject() {
        let panel = NSOpenPanel()
        panel.title = "プロジェクトを開く"
        panel.allowedContentTypes = Self.projectContentTypes
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(at: url)
    }

    /// Finder からのダブルクリックなどで渡された URL を開く。
    func openProject(at url: URL) {
        let ext = url.pathExtension.lowercased()
        guard Transcript.allProjectFileExtensions.contains(ext) else {
            #if CLAUDE_TRANS
            if AudioFileTypes.isSupported(url) {
                projectURL = nil
                transcript = nil
                isDirty = false
                undoStack.removeAll()
                pendingContext = nil
                pendingGlossary = nil
                attachAudio(url, securityScoped: false)
                infoSheet = .transcribe
                return
            }
            #endif
            errorMessage = "開けないファイルです: \(url.lastPathComponent)"
            return
        }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let loaded = try Transcript.fromProjectData(data)
            transcript = loaded
            projectURL = url
            isDirty = false
            undoStack.removeAll()
            restoreAudio(from: loaded)
        } catch {
            errorMessage = "プロジェクトを読み込めませんでした: \(error.localizedDescription)"
        }
    }

    func saveProject() {
        guard let transcript else { return }
        let url: URL
        if let projectURL {
            url = projectURL
        } else {
            let panel = NSSavePanel()
            panel.title = "プロジェクトを保存"
            panel.allowedContentTypes = [UTType(filenameExtension: Transcript.projectFileExtension) ?? .json]
            panel.nameFieldStringValue = defaultBaseName + "." + Transcript.projectFileExtension
            panel.allowsOtherFileTypes = false
            guard panel.runModal() == .OK, let u = panel.url else { return }
            url = u
        }
        do {
            try transcript.projectData().write(to: url)
            projectURL = url
            isDirty = false
        } catch {
            errorMessage = "保存に失敗しました: \(error.localizedDescription)"
        }
    }

    /// ウインドウのタイトル。プロジェクトを開いている／保存済みならその名前、まだなら音声ファイル名。
    var windowTitle: String {
        if let projectURL { return projectURL.deletingPathExtension().lastPathComponent }
        return transcript?.sourceFileName ?? audioURL?.lastPathComponent ?? AppInfo.name
    }

    var defaultBaseName: String {
        let name = transcript?.sourceFileName ?? audioURL?.lastPathComponent ?? "transcript"
        return (name as NSString).deletingPathExtension
    }

    // MARK: - Transcription

    #if CLAUDE_TRANS
    func startTranscription() {
        guard let audioURL, !isProcessing else { return }
        var options = makePipelineOptions()
        if options.useClaude && options.claude == nil {
            errorMessage = "Claude の API キーが未設定です。設定画面（⌘,）で入力するか、設定で「Claude で校正」をオフにしてください。"
            return
        }
        // 同梱音声から再文字起こしするときは、圧縮し直さず前の同梱音声と元ファイル参照を引き継ぐ
        let usingEmbedded = isUsingEmbeddedAudio
        let previous = transcript
        options.embedAudio = settings.embedAudio && !usingEmbedded
        isProcessing = true
        progress = PipelineProgress(stage: .loading, fraction: 0)
        errorMessage = nil
        runningTask = Task {
            do {
                let pipeline = TranscriptionPipeline()
                let result = try await pipeline.runDetailed(url: audioURL, options: options) { [weak self] p in
                    Task { @MainActor in self?.progress = p }
                }
                var transcript = result.transcript
                if usingEmbedded, let previous {
                    transcript.sourceFileName = previous.sourceFileName
                    transcript.sourceFilePath = previous.sourceFilePath
                    transcript.sourceBookmark = previous.sourceBookmark
                    transcript.embeddedAudio = previous.embeddedAudio
                } else {
                    self.storeAudioReference(audioURL, into: &transcript)
                }
                transcript.context = self.pendingContext ?? self.settings.context
                transcript.glossary = self.pendingGlossary ?? self.settings.glossary
                self.transcript = transcript
                self.undoStack.removeAll()
                if !self.playback.isLoaded { self.attachAudio(audioURL, securityScoped: false) }
                self.warningMessage = result.warning
            } catch is CancellationError {
                // キャンセル
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.isProcessing = false
            self.progress = nil
        }
    }

    /// 既存の文字起こしに Claude 校正だけ再適用する（原文があれば原文から）。
    func refineOnly() {
        guard var t = transcript, !isProcessing else { return }
        guard let key = KeychainStore.loadAPIKey() else {
            errorMessage = "Claude の API キーが未設定です。設定画面（⌘,）で入力してください。"
            return
        }
        for i in t.segments.indices {
            if let original = t.segments[i].originalText {
                t.segments[i].text = original
            }
        }
        let refiner = TranscriptRefiner(client: ClaudeClient(config: makeClaudeConfig(key: key)),
                                        options: makeRefinerOptions(context: t.context, glossary: t.glossary))
        isProcessing = true
        progress = PipelineProgress(stage: .refining, fraction: 0)
        pushUndo()
        let source = t
        runningTask = Task {
            let outcome = await refiner.refineTolerant(source) { [weak self] rp in
                Task { @MainActor in
                    self?.progress = PipelineProgress(stage: .refining, fraction: rp.fraction,
                                                      detail: "\(rp.completedChunks)/\(rp.totalChunks) ブロック")
                }
            }
            self.transcript = outcome.transcript
            if outcome.failedChunks > 0 {
                self.warningMessage = "Claude の校正が \(outcome.totalChunks) ブロック中 \(outcome.failedChunks) ブロックで失敗しました。その部分は元のままです。" + (outcome.lastErrorDescription.map { "\n\n原因: \($0)" } ?? "")
            }
            self.isProcessing = false
            self.progress = nil
        }
    }

    func cancel() {
        runningTask?.cancel()
        runningTask = nil
        isProcessing = false
        progress = nil
    }

    // MARK: - Embedded audio

    /// 今結び付いている音声を圧縮してプロジェクトに同梱する（保存すると .ccot に含まれる）。
    func embedAudio() {
        guard transcript != nil, let audioURL, !isProcessing else { return }
        if isUsingEmbeddedAudio {
            lastReplaceMessage = "この音声はすでに同梱されています"
            return
        }
        isProcessing = true
        progress = PipelineProgress(stage: .compressing, fraction: 0)
        runningTask = Task {
            do {
                let worker = Task.detached(priority: .userInitiated) { [weak self] in
                    try AudioCompressor.embeddedAudio(for: audioURL) { p in
                        Task { @MainActor in
                            self?.progress = PipelineProgress(stage: .compressing, fraction: p)
                        }
                    }
                }
                let audio = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                if var t = self.transcript {
                    t.embeddedAudio = audio
                    self.transcript = t
                    let size = ByteCountFormatter.string(fromByteCount: Int64(audio.byteCount), countStyle: .file)
                    self.lastReplaceMessage = "音声を同梱しました（\(size)）。保存（⌘S）すると .ccot に含まれます"
                }
            } catch is CancellationError {
                // 中止
            } catch {
                self.errorMessage = "音声を圧縮できませんでした: \(error.localizedDescription)"
            }
            self.isProcessing = false
            self.progress = nil
        }
    }

    /// 同梱した音声をプロジェクトから外す（ファイルを小さくしたいとき）。
    func removeEmbeddedAudio() {
        guard var t = transcript, t.embeddedAudio != nil else { return }
        if isUsingEmbeddedAudio {
            errorMessage = "同梱した音声で再生しているため外せません。「再生」メニューの「音声ファイルを指定…」で元の音声を結び付けてから外してください。"
            return
        }
        t.embeddedAudio = nil
        transcript = t
        lastReplaceMessage = "同梱した音声を外しました。保存（⌘S）すると .ccot から消えます"
    }

    private func makeClaudeConfig(key: String) -> ClaudeConfig {
        ClaudeConfig(apiKey: key, model: settings.model, effort: settings.effort)
    }

    private func makeRefinerOptions(context: String? = nil, glossary: String? = nil) -> RefinerOptions {
        var r = RefinerOptions()
        r.chunkCharacters = max(500, settings.chunkCharacters)
        r.glossary = glossary ?? pendingGlossary ?? settings.glossary
        r.context = context ?? pendingContext ?? settings.context
        r.allowSpeakerFix = settings.allowSpeakerFix
        r.removeFillers = settings.removeFillers
        return r
    }

    private func makePipelineOptions() -> PipelineOptions {
        var o = PipelineOptions()
        o.useDiarization = settings.useDiarization
        o.useClaude = settings.useClaude
        if settings.useClaude, let key = KeychainStore.loadAPIKey() {
            o.claude = makeClaudeConfig(key: key)
        }
        o.refiner = makeRefinerOptions()
        return o
    }
    #endif

    // MARK: - Editing

    func binding(for segmentID: Int) -> Binding<String> {
        Binding(
            get: { self.transcript?.segments.first(where: { $0.id == segmentID })?.text ?? "" },
            set: { newValue in
                guard var t = self.transcript, let idx = t.segments.firstIndex(where: { $0.id == segmentID }) else { return }
                if t.segments[idx].text != newValue {
                    t.segments[idx].text = newValue
                    self.transcript = t
                }
            }
        )
    }

    func setSpeaker(_ speaker: String, for segmentID: Int) {
        guard var t = transcript, let idx = t.segments.firstIndex(where: { $0.id == segmentID }) else { return }
        t.segments[idx].speaker = speaker
        transcript = t
    }

    func addSpeaker() -> String {
        guard var t = transcript else { return "" }
        let n = (t.speakers.compactMap { Int($0.dropFirst(2)) }.max() ?? 0) + 1
        let label = "話者\(n)"
        // 空のラベルを登録するために speakerNames に空文字を入れておく
        t.speakerNames[label] = t.speakerNames[label] ?? ""
        transcript = t
        return label
    }

    func speakerNameBinding(_ label: String) -> Binding<String> {
        Binding(
            get: { self.transcript?.speakerNames[label] ?? "" },
            set: { v in
                guard var t = self.transcript else { return }
                t.speakerNames[label] = v
                self.transcript = t
            }
        )
    }

    /// 話者一覧（発話に登場するもの＋追加されたラベル）
    var allSpeakers: [String] {
        guard let t = transcript else { return [] }
        var list = t.speakers
        for k in t.speakerNames.keys where !list.contains(k) { list.append(k) }
        return list.sorted { a, b in
            let na = Int(a.dropFirst(2)) ?? Int.max
            let nb = Int(b.dropFirst(2)) ?? Int.max
            return na == nb ? a < b : na < nb
        }
    }

    /// Tab / ⇧Tab: フォーカスを次（前）の発話の本文へ移す。
    func focusAdjacentSegment(_ delta: Int) {
        guard let t = transcript, !t.segments.isEmpty else { return }
        let idx: Int
        if let id = focusedSegmentID, let i = t.segments.firstIndex(where: { $0.id == id }) {
            idx = i
        } else {
            idx = delta > 0 ? -1 : t.segments.count
        }
        let next = idx + delta
        guard t.segments.indices.contains(next) else { return }
        focusedSegmentID = t.segments[next].id
    }

    // MARK: - Split / merge

    /// フォーカス中の本文のカーソル位置で分割する。
    func splitFocusedSegmentAtCursor() {
        guard let id = focusedSegmentID,
              let tv = NSApp.keyWindow?.firstResponder as? NSTextView else {
            lastReplaceMessage = "分割したい位置に本文のカーソルを置いてから実行してください"
            return
        }
        splitSegment(id, atUTF16Offset: tv.selectedRange().location)
    }

    func splitSegment(_ segmentID: Int, atUTF16Offset loc: Int) {
        guard var t = transcript, let idx = t.segments.firstIndex(where: { $0.id == segmentID }) else { return }
        let seg = t.segments[idx]
        let ns = seg.text as NSString
        guard loc > 0, loc < ns.length else {
            lastReplaceMessage = "先頭や末尾では分割できません。分けたい位置にカーソルを置いてください"
            return
        }
        let head = ns.substring(to: loc).trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = ns.substring(from: loc).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !head.isEmpty, !tail.isEmpty else { return }
        pushUndo()
        let ratio = Double(loc) / Double(ns.length)
        let splitTime = seg.start + (seg.end - seg.start) * ratio
        let newID = (t.segments.map(\.id).max() ?? 0) + 1
        t.segments[idx].text = head
        t.segments[idx].end = splitTime
        t.segments.insert(TranscriptSegment(id: newID, speaker: seg.speaker, start: splitTime, end: seg.end, text: tail), at: idx + 1)
        transcript = t
        lastReplaceMessage = "発話を分割しました"
    }

    /// 「。」「？」「！」ごとに分割する。
    func splitSegmentAtSentences(_ segmentID: Int) {
        guard var t = transcript, let idx = t.segments.firstIndex(where: { $0.id == segmentID }) else { return }
        let seg = t.segments[idx]
        let enders: Set<Character> = ["。", "？", "！", "?", "!"]
        var pieces: [String] = []
        var current = ""
        for ch in seg.text {
            current.append(ch)
            if enders.contains(ch) {
                pieces.append(current)
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { pieces.append(current) }
        pieces = pieces.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard pieces.count >= 2 else {
            lastReplaceMessage = "句点が見つからないため分割できません"
            return
        }
        pushUndo()
        let total = Double(pieces.reduce(0) { $0 + $1.count })
        var nextID = (t.segments.map(\.id).max() ?? 0) + 1
        var cursor = seg.start
        var newSegs: [TranscriptSegment] = []
        for (i, p) in pieces.enumerated() {
            let len = (seg.end - seg.start) * Double(p.count) / max(1, total)
            let end = i == pieces.count - 1 ? seg.end : cursor + len
            if i == 0 {
                var first = seg
                first.text = p
                first.end = end
                newSegs.append(first)
            } else {
                newSegs.append(TranscriptSegment(id: nextID, speaker: seg.speaker, start: cursor, end: end, text: p))
                nextID += 1
            }
            cursor = end
        }
        t.segments.replaceSubrange(idx...idx, with: newSegs)
        transcript = t
        lastReplaceMessage = "\(pieces.count) 個の発話に分割しました"
    }

    /// 指定した発話の前後に空の発話を挿入する（被った発言・聞き落としを手で足す用）。
    func insertSegment(relativeTo segmentID: Int, after: Bool) {
        guard var t = transcript, let idx = t.segments.firstIndex(where: { $0.id == segmentID }) else { return }
        pushUndo()
        let anchor = t.segments[idx]
        let insertIndex = after ? idx + 1 : idx
        // 時刻: 隣との境界に置く。後ろに入れるなら「この発話の終わり〜次の発話の始まり」
        let start: Double
        let end: Double
        if after {
            start = anchor.end
            end = insertIndex < t.segments.count ? max(t.segments[insertIndex].start, start + 0.5) : start + 1
        } else {
            end = anchor.start
            start = idx > 0 ? min(t.segments[idx - 1].end, end - 0.5) : max(0, end - 1)
        }
        // 話者: 隣と違う話者を優先
        let others = allSpeakers.filter { $0 != anchor.speaker }
        let speaker = others.first ?? anchor.speaker
        let newID = (t.segments.map(\.id).max() ?? 0) + 1
        t.segments.insert(TranscriptSegment(id: newID, speaker: speaker, start: max(0, start), end: max(end, start), text: ""), at: insertIndex)
        transcript = t
        focusedSegmentID = newID
        lastReplaceMessage = after ? "この発話の後に空の発話を挿入しました" : "この発話の前に空の発話を挿入しました"
    }

    // MARK: - Multi-selection

    func toggleSelection(_ segmentID: Int) {
        if selectedSegmentIDs.contains(segmentID) {
            selectedSegmentIDs.remove(segmentID)
        } else {
            selectedSegmentIDs.insert(segmentID)
        }
    }

    func clearSelection() { selectedSegmentIDs.removeAll() }

    /// 選択した発話を、文書順に最初の発話へまとめる（話者は最初の発話のもの）。
    func mergeSelected() {
        guard var t = transcript else { return }
        let indices = t.segments.indices.filter { selectedSegmentIDs.contains(t.segments[$0].id) }
        guard indices.count >= 2, let first = indices.first else {
            lastReplaceMessage = "つなげるには2件以上選択してください"
            return
        }
        pushUndo()
        var merged = t.segments[first]
        for i in indices.dropFirst() {
            merged.text += t.segments[i].text
            merged.end = max(merged.end, t.segments[i].end)
        }
        merged.originalText = nil
        t.segments[first] = merged
        for i in indices.dropFirst().reversed() { t.segments.remove(at: i) }
        transcript = t
        selectedSegmentIDs.removeAll()
        lastReplaceMessage = "\(indices.count) 件をつなげました"
    }

    func setSpeakerForSelected(_ speaker: String) {
        guard var t = transcript, !selectedSegmentIDs.isEmpty else { return }
        pushUndo()
        var n = 0
        for i in t.segments.indices where selectedSegmentIDs.contains(t.segments[i].id) {
            t.segments[i].speaker = speaker
            n += 1
        }
        transcript = t
        lastReplaceMessage = "\(n) 件の話者を「\(t.displayName(for: speaker))」にしました"
    }

    func deleteSelected() {
        guard var t = transcript, !selectedSegmentIDs.isEmpty else { return }
        pushUndo()
        let n = selectedSegmentIDs.count
        t.segments.removeAll { selectedSegmentIDs.contains($0.id) }
        transcript = t
        selectedSegmentIDs.removeAll()
        lastReplaceMessage = "\(n) 件を削除しました"
    }

    /// 連続する同じ話者の発話を全体にわたって1つにつなげる（仕上げ用）。
    func mergeConsecutiveSameSpeaker() {
        guard var t = transcript, t.segments.count >= 2 else { return }
        var merged: [TranscriptSegment] = []
        var joined = 0
        for seg in t.segments {
            if var last = merged.last, last.speaker == seg.speaker {
                last.text += seg.text
                last.end = max(last.end, seg.end)
                last.originalText = nil
                merged[merged.count - 1] = last
                joined += 1
            } else {
                merged.append(seg)
            }
        }
        guard joined > 0 else {
            lastReplaceMessage = "連続する同じ話者の発話はありません"
            return
        }
        pushUndo()
        t.segments = merged
        transcript = t
        selectedSegmentIDs.removeAll()
        lastReplaceMessage = "\(joined) か所をつなげて \(merged.count) 発話にしました（⌘Z で戻せます）"
    }

    func mergeSegmentWithNext(_ segmentID: Int) {
        guard var t = transcript, let idx = t.segments.firstIndex(where: { $0.id == segmentID }), idx + 1 < t.segments.count else { return }
        pushUndo()
        t.segments[idx].text += t.segments[idx + 1].text
        t.segments[idx].end = t.segments[idx + 1].end
        t.segments.remove(at: idx + 1)
        transcript = t
        lastReplaceMessage = "次の発話とつなげました"
    }

    func mergeSegmentWithPrevious(_ segmentID: Int) {
        guard var t = transcript, let idx = t.segments.firstIndex(where: { $0.id == segmentID }), idx > 0 else { return }
        pushUndo()
        t.segments[idx - 1].text += t.segments[idx].text
        t.segments[idx - 1].end = t.segments[idx].end
        t.segments.remove(at: idx)
        transcript = t
        lastReplaceMessage = "前の発話とつなげました"
    }

    func deleteSegment(_ segmentID: Int) {
        guard var t = transcript, let idx = t.segments.firstIndex(where: { $0.id == segmentID }) else { return }
        pushUndo()
        t.segments.remove(at: idx)
        transcript = t
    }

    // MARK: - Find / replace

    func replaceAll() {
        guard var t = transcript, !findQuery.isEmpty else { return }
        if let msg = findValidationMessage { lastReplaceMessage = msg; return }
        pushUndo()
        let n = FindReplace.apply(to: &t, query: findQuery, replacement: replaceText, options: findOptions)
        transcript = t
        lastReplaceMessage = n == 0 ? "一致する箇所はありませんでした" : "\(n) 件を「\(replaceText)」に置き換えました"
    }

    private func pushUndo() {
        guard let transcript else { return }
        undoStack.append(transcript)
        if undoStack.count > 30 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        if let current = transcript { redoStack.append(current) }
        transcript = last
        lastReplaceMessage = "元に戻しました"
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        if let current = transcript { undoStack.append(current) }
        transcript = next
        lastReplaceMessage = "やり直しました"
    }

    /// ⌘Z: 本文を入力中なら文字の取り消し、そうでなければ置換・分割・統合などの取り消し。
    func smartUndo() {
        if let tv = NSApp.keyWindow?.firstResponder as? NSTextView, let um = tv.undoManager, um.canUndo {
            um.undo()
            return
        }
        undo()
    }

    func smartRedo() {
        if let tv = NSApp.keyWindow?.firstResponder as? NSTextView, let um = tv.undoManager, um.canRedo {
            um.redo()
            return
        }
        redo()
    }

    // MARK: - Export

    func export(format: ExportFormat) {
        guard let transcript else { return }
        let panel = NSSavePanel()
        panel.title = "書き出し"
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .data]
        panel.nameFieldStringValue = defaultBaseName + "." + format.fileExtension
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let options = ExportOptions(includeTimestamps: settings.exportTimestamps,
                                        includeSpeakers: settings.exportSpeakers,
                                        mergeConsecutiveSpeakers: settings.exportMerge)
            let data = try Exporter.data(for: transcript, format: format, options: options)
            try data.write(to: url)
            if format == .json { projectURL = url; isDirty = false }
        } catch {
            errorMessage = "書き出しに失敗しました: \(error.localizedDescription)"
        }
    }

    // MARK: - API key

    #if CLAUDE_TRANS
    func saveAPIKey(_ key: String) {
        do {
            try KeychainStore.saveAPIKey(key)
            apiKeyPresent = KeychainStore.loadAPIKey() != nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    #endif
}

/// 再生・読み込みに対応する音声ファイルの拡張子（両エディション共通）。
enum AudioFileTypes {
    static let supportedExtensions = ["mp3", "wav", "m4a", "aac", "aiff", "aif", "caf", "flac", "mp4", "mov"]
    static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }
}


/// サンドボックス内でパスだけから開けるか確かめる。
enum AVAudioPlayerProbe {
    static func canOpen(_ url: URL) throws -> Bool {
        _ = try FileHandle(forReadingFrom: url)
        return true
    }
}

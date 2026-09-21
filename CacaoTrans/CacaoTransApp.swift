import SwiftUI
import AppKit

/// ビルド対象ごとの名前。CLAUDE_TRANS が定義されていれば文字起こし版、なければ編集専用版。
enum AppInfo {
    #if CLAUDE_TRANS
    static let name = "CacaoClaudeTrans"
    static let isClaudeEdition = true
    #else
    static let name = "CacaoTrans"
    static let isClaudeEdition = false
    #endif
}

@main
struct CacaoTransApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.playback)
                .frame(minWidth: 900, minHeight: 600)
                .onOpenURL { url in model.openProject(at: url) }
        }
        .commands {
            CommandGroup(replacing: .systemServices) {}
            CommandGroup(replacing: .newItem) {
                #if CLAUDE_TRANS
                Button("音声ファイルを開く…") { model.openAudio() }
                    .keyboardShortcut("o")
                Button("プロジェクトを開く…") { model.openProject() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                #else
                Button("プロジェクトを開く…") { model.openProject() }
                    .keyboardShortcut("o")
                #endif
                Divider()
                Button("プロジェクトを保存") { model.saveProject() }
                    .keyboardShortcut("s")
                    .disabled(model.transcript == nil)
                Button("書き出し…") { model.showExport = true }
                    .keyboardShortcut("e")
                    .disabled(model.transcript == nil)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("元に戻す") { model.smartUndo() }
                    .keyboardShortcut("z", modifiers: [.command])
                Button("やり直す") { model.smartRedo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(after: .textEditing) {
                Button("検索と置換") { model.showFindReplace.toggle() }
                    .keyboardShortcut("f")
                    .disabled(model.transcript == nil)
                Divider()
                Button("カーソル位置で発話を分割") { model.splitFocusedSegmentAtCursor() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(model.transcript == nil)
                Button("句点（。？！）で発話を分割") {
                    if let id = model.focusedSegmentID { model.splitSegmentAtSentences(id) }
                }
                .keyboardShortcut(.return, modifiers: [.command, .option])
                .disabled(model.focusedSegmentID == nil)
                Button("前の発話とつなげる") {
                    if let id = model.focusedSegmentID { model.mergeSegmentWithPrevious(id) }
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(model.focusedSegmentID == nil)
                Button("次の発話とつなげる") {
                    if let id = model.focusedSegmentID { model.mergeSegmentWithNext(id) }
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(model.focusedSegmentID == nil)
                Divider()
                Button("選択した発話をつなげる") { model.mergeSelected() }
                    .keyboardShortcut("j", modifiers: [.command])
                    .disabled(model.selectedSegmentIDs.count < 2)
                Button("選択を解除") { model.clearSelection() }
                    .disabled(model.selectedSegmentIDs.isEmpty)
                Divider()
                Button("この発話の後に発話を挿入") {
                    if let id = model.focusedSegmentID { model.insertSegment(relativeTo: id, after: true) }
                }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(model.focusedSegmentID == nil)
                Button("この発話の前に発話を挿入") {
                    if let id = model.focusedSegmentID { model.insertSegment(relativeTo: id, after: false) }
                }
                .keyboardShortcut(.return, modifiers: [.command, .shift, .option])
                .disabled(model.focusedSegmentID == nil)
            }
            CommandMenu("再生") {
                Button("再生 / 一時停止") { model.playback.togglePlayPause() }
                    .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF8FunctionKey)!)), modifiers: [])
                    .disabled(!model.playback.isLoaded)
                Button("次の発話") { model.playback.playNext() }
                    .keyboardShortcut(.downArrow, modifiers: [.command])
                    .disabled(!model.playback.isLoaded)
                Button("前の発話") { model.playback.playPrevious() }
                    .keyboardShortcut(.upArrow, modifiers: [.command])
                    .disabled(!model.playback.isLoaded)
                Divider()
                Button("音声フォルダを設定…") { model.chooseAudioFolder() }
                Button("音声ファイルを指定…") { model.relinkAudio() }
                    .disabled(model.transcript == nil)
            }
            #if CLAUDE_TRANS
            CommandMenu("文字起こし") {
                Button("文字起こしを開始…") { model.requestTranscription() }
                    .keyboardShortcut("r")
                    .disabled(model.audioURL == nil || model.isProcessing)
                Button("Claude で校正だけやり直す…") { model.requestRefine() }
                    .disabled(model.transcript == nil || model.isProcessing)
                Divider()
                Button("この音声について（背景・用語集）…") { model.infoSheet = .edit }
                    .disabled(model.transcript == nil)
            }
            #endif
        }
        #if CLAUDE_TRANS
        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(model.playback)
        }
        #endif
    }
}

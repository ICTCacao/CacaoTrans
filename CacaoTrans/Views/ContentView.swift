import SwiftUI
import CacaoTransCore
import AppKit

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
            } detail: {
                Group {
                    if model.transcript != nil {
                        TranscriptListView()
                    } else {
                        EmptyStateView()
                    }
                }
                .inspector(isPresented: $model.showFindReplace) {
                    FindReplaceView()
                        .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
                }
            }
            if model.transcript != nil {
                PlayerBar()
            }
        }
        .toolbar { toolbarContent }
        #if CLAUDE_TRANS
        .sheet(isPresented: Binding(get: { model.isProcessing }, set: { _ in })) {
            ProgressSheet()
        }
        #endif
        .sheet(isPresented: $model.showExport) {
            ExportSheet()
        }
        .sheet(item: $model.infoSheet) { mode in
            ProjectInfoSheet(mode: mode)
        }
        .alert("エラー", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("注意", isPresented: Binding(get: { model.warningMessage != nil }, set: { if !$0 { model.warningMessage = nil } })) {
            Button("OK") { model.warningMessage = nil }
        } message: {
            Text(model.warningMessage ?? "")
        }
        .navigationTitle(model.windowTitle)
        .navigationSubtitle(model.isDirty ? "未保存の変更あり" : "")
        .onAppear { AppDelegate.reopenWindow = { openWindow(id: "main") } }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Image(AppInfo.isClaudeEdition ? "ToolbarGlyphClaude" : "ToolbarGlyph")
                .renderingMode(.original)
                .resizable()
                .interpolation(.high)
                .frame(width: 26, height: 26)
                .help(AppInfo.name)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItemGroup(placement: .primaryAction) {
            #if CLAUDE_TRANS
            Button { model.openAudio() } label: { Label("音声を開く", systemImage: "waveform.badge.plus") }
                .help("音声ファイルを開いて文字起こしを始める（⌘O）")
            Button { model.requestTranscription() } label: { Label("再実行", systemImage: "arrow.clockwise") }
                .disabled(model.audioURL == nil || model.isProcessing)
                .help("同じ音声で文字起こしをやり直す（⌘R）")
            #else
            Button { model.openProject() } label: { Label("プロジェクトを開く", systemImage: "folder") }
                .help("保存したプロジェクト（.ccot）を開く（⌘O）")
            #endif
            Divider()
            Button { model.showFindReplace.toggle() } label: { Label("検索・置換", systemImage: "text.magnifyingglass") }
                .disabled(model.transcript == nil)
                .help("一括で検索・置換する（⌘F）")
            Button { model.saveProject() } label: { Label("保存", systemImage: "square.and.arrow.down") }
                .disabled(model.transcript == nil)
                .help("プロジェクトとして保存（⌘S）")
            Button { model.showExport = true } label: { Label("書き出し", systemImage: "square.and.arrow.up") }
                .disabled(model.transcript == nil)
                .help("テキストや Word に書き出す（⌘E）")
        }
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            #if CLAUDE_TRANS
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("音声ファイルを開いて文字起こしを始めましょう")
                .font(.title3)
            Text("mp3 / wav / m4a などに対応。音声認識はこの Mac の中で行い、Claude が誤変換や話者を整えます。")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack {
                Button("音声ファイルを開く…") { model.openAudio() }
                    .buttonStyle(.borderedProminent)
                Button("プロジェクトを開く…") { model.openProject() }
            }
            if !model.apiKeyPresent {
                Label("Claude の API キーが未設定です。設定（⌘,）で入力してください。", systemImage: "key")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(.top, 8)
            }
            #else
            Image(systemName: "text.document")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("プロジェクト（.ccot）を開いて編集しましょう")
                .font(.title3)
            Text("CacaoClaudeTrans で作った文字起こしを開き、再生しながら発話の分割・統合・話者の付け替え・置換・書き出しができます。音声が同梱されたプロジェクトなら、そのまま再生できます。")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Button("プロジェクトを開く…") { model.openProject() }
                .buttonStyle(.borderedProminent)
            HStack(spacing: 6) {
                Image(systemName: "folder")
                Text("音声フォルダ（音声が別ファイルのとき）: \(model.audioFolder.displayPath)")
                Button("変更…") { model.chooseAudioFolder() }
                    .controlSize(.small)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 8)
            #endif
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List {
            if let t = model.transcript {
                Section("ファイル") {
                    LabeledContent("名前", value: t.sourceFileName)
                    LabeledContent("長さ", value: Transcript.formatTime(t.duration, alwaysHours: true))
                    LabeledContent("発話数", value: "\(t.segments.count)")
                    LabeledContent("文字数", value: "\(t.characterCount)")
                    LabeledContent("音声", value: model.audioSourceDescription)
                        .help(model.audioSourceHelp)
                    #if CLAUDE_TRANS
                    if t.embeddedAudio == nil {
                        Button {
                            model.embedAudio()
                        } label: {
                            Label("音声を圧縮して同梱", systemImage: "waveform.badge.plus")
                        }
                        .disabled(model.audioURL == nil || model.isProcessing)
                        .help(".ccot だけで再生できるよう、音声を圧縮してプロジェクトに含める")
                    } else {
                        Button {
                            model.removeEmbeddedAudio()
                        } label: {
                            Label("同梱した音声を外す", systemImage: "waveform.badge.minus")
                        }
                        .disabled(model.isProcessing)
                    }
                    #endif
                }
                Section {
                    let ctx = (t.context ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    Text(ctx.isEmpty ? "（未入力）" : ctx)
                        .font(.caption)
                        .foregroundStyle(ctx.isEmpty ? .tertiary : .secondary)
                        .lineLimit(4)
                    HStack {
                        let gl = (t.glossary ?? "").split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
                        Text("用語集 \(gl) 件").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("編集…") { model.infoSheet = .edit }.controlSize(.small)
                    }
                } header: {
                    Text("この音声について")
                }
                Section {
                    ForEach(model.allSpeakers, id: \.self) { label in
                        HStack {
                            Circle().fill(SpeakerColor.color(for: label)).frame(width: 10, height: 10)
                            Text(label).frame(width: 44, alignment: .leading)
                            TextField("表示名", text: model.speakerNameBinding(label))
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    Button {
                        _ = model.addSpeaker()
                    } label: {
                        Label("話者を追加", systemImage: "person.badge.plus")
                    }
                } header: {
                    Text("話者")
                } footer: {
                    Text("表示名を入れると書き出し時にその名前になります。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let url = model.audioURL {
                Section("ファイル") {
                    Text(url.lastPathComponent)
                }
            }
            #if CLAUDE_TRANS
            Section("設定") {
                Toggle("Claude で校正", isOn: $model.settings.useClaude)
                Toggle("話者を分離", isOn: $model.settings.useDiarization)
                LabeledContent("モデル", value: model.settings.model)
                    .font(.caption)
            }
            #endif
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Text(Self.versionText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
    }

    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        let name = info?["CFBundleName"] as? String ?? ""
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        return "\(name) バージョン \(version)"
    }
}

enum SpeakerColor {
    static let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .brown, .indigo]
    static func color(for label: String) -> Color {
        let n = Int(label.dropFirst(2)) ?? (abs(label.hashValue) % palette.count + 1)
        return palette[(max(1, n) - 1) % palette.count]
    }
}

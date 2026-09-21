#if CLAUDE_TRANS
import SwiftUI
import CacaoTransCore
import CacaoTransEngine

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var apiKeyInput = ""
    @State private var apiKeyStatus: String?

    var body: some View {
        TabView {
            claudeTab
                .tabItem { Label("Claude", systemImage: "sparkles") }
            transcriptionTab
                .tabItem { Label("文字起こし", systemImage: "waveform") }
            glossaryTab
                .tabItem { Label("用語集", systemImage: "book") }
        }
        .frame(width: 560, height: 440)
    }

    private var claudeTab: some View {
        Form {
            Section {
                HStack {
                    SecureField("sk-ant-api03-…", text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                    Button("保存") {
                        model.saveAPIKey(apiKeyInput)
                        apiKeyStatus = model.apiKeyPresent ? "キーチェーンに保存しました" : "キーを削除しました"
                        apiKeyInput = ""
                    }
                    .disabled(apiKeyInput.isEmpty && !model.apiKeyPresent)
                }
                HStack {
                    Image(systemName: model.apiKeyPresent ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(model.apiKeyPresent ? .green : .secondary)
                    Text(model.apiKeyPresent ? "API キーは保存済み（macOS キーチェーン）" : "API キーが未設定")
                    Spacer()
                    if model.apiKeyPresent {
                        Button("削除") {
                            model.saveAPIKey("")
                            apiKeyStatus = "キーを削除しました"
                        }
                    }
                }
                if let apiKeyStatus {
                    Text(apiKeyStatus).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("API キー")
            } footer: {
                Text("Anthropic Console（console.anthropic.com）で発行したキーを入力します。claude.ai の Pro / Max 契約とは別で、従量課金です。")
                    .font(.caption)
            }
            Section("モデル") {
                Picker("モデル", selection: $model.settings.model) {
                    ForEach(ClaudeConfig.availableModels, id: \.self) { Text($0).tag($0) }
                }
                Text(ClaudeConfig.description(for: model.settings.model))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("思考の深さ（effort）", selection: $model.settings.effort) {
                    Text("低（速い・安い）").tag("low")
                    Text("中（標準）").tag("medium")
                    Text("高（丁寧）").tag("high")
                }
                .disabled(!ClaudeConfig.supportsAdaptiveThinking(model.settings.model))
                Stepper("1回に送る文字数: \(model.settings.chunkCharacters)", value: $model.settings.chunkCharacters, in: 800...6000, step: 200)
            }
            Section("校正の方針") {
                Toggle("フィラー（えー・あの）を軽く取り除く", isOn: $model.settings.removeFillers)
                Toggle("明らかな話者の取り違えを直させる", isOn: $model.settings.allowSpeakerFix)
            }
        }
        .formStyle(.grouped)
    }

    private var transcriptionTab: some View {
        Form {
            Section("処理") {
                Toggle("Claude で校正する", isOn: $model.settings.useClaude)
                Toggle("話者を分離する", isOn: $model.settings.useDiarization)
            }
            Section {
                TextField("例: 地域の子育て支援に関する3人のインタビュー", text: $model.settings.context)
                    .textFieldStyle(.roundedBorder)
            } header: {
                Text("音声の背景の初期値")
            } footer: {
                Text("文字起こしを始めるとき「この音声について」シートにこの内容が入った状態で出ます。音声ごとの背景はそこで書き換え、プロジェクトに保存されます。")
                    .font(.caption)
            }
            Section("音声認識") {
                LabeledContent("エンジン", value: "Apple SpeechAnalyzer（オンデバイス・日本語）")
                LabeledContent("話者分離", value: "FluidAudio（CoreML・オンデバイス）")
                LabeledContent("利用可否", value: SpeechTranscriptionService.isAvailable ? "利用できます" : "利用できません")
            }
        }
        .formStyle(.grouped)
    }

    private var glossaryTab: some View {
        Form {
            Section {
                TextEditor(text: $model.settings.glossary)
                    .font(.body)
                    .frame(minHeight: 260)
            } header: {
                Text("用語集の初期値（1行に1つ）")
            } footer: {
                Text("すべての音声に共通する固有名詞・専門用語をここに。文字起こし開始時のシートにこの内容が入り、音声ごとに追記してプロジェクトに保存されます。例:\n山田太郎（やまだ・たろう）: 事務局長\nCGW: 当社の顧客管理システム")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
    }
}
#endif

import SwiftUI
import CacaoTransCore

struct FindReplaceView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                Label("検索・置換", systemImage: "text.magnifyingglass")
                    .font(.headline)
            }
            Section("検索と置換") {
                TextField("検索する語句", text: $model.findQuery)
                    .textFieldStyle(.roundedBorder)
                TextField("置き換える語句", text: $model.replaceText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.replaceAll() }
                Toggle("大文字と小文字を区別", isOn: $model.findOptions.caseSensitive)
                Toggle("正規表現を使う", isOn: $model.findOptions.useRegex)
            }
            Section {
                HStack {
                    if let msg = model.findValidationMessage {
                        Label(msg, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    } else if model.findQuery.isEmpty {
                        Text("語句を入力すると一致件数が出ます").foregroundStyle(.secondary)
                    } else {
                        Text("\(model.matchCount) 件")
                            .font(.title3.weight(.semibold))
                    }
                    Spacer()
                }
                // 横並びにしない: 件数の文字幅が変わるとインスペクタ列の最小幅が変わり、AppKit の制約更新中に落ちる
                Toggle("一致する発話だけ表示", isOn: $model.showOnlyMatches)
                    .toggleStyle(.switch)
                    .disabled(model.findQuery.isEmpty)
                HStack {
                    Button("すべて置換") { model.replaceAll() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.findQuery.isEmpty || model.matchCount == 0 || model.findValidationMessage != nil)
                    Button("元に戻す") { model.undo() }
                        .disabled(!model.canUndo)
                    Spacer()
                    Button("クリア") { model.clearFind() }
                        .disabled(model.findQuery.isEmpty && model.replaceText.isEmpty)
                        .help("検索語・置換語・絞り込みを空にする")
                }
            }
            Section("使い方のヒント") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("漢字の誤変換は「機械 → 機会」のように語句で置換できます。")
                    Text("正規表現をオンにすると「機械(が|を)」→「機会$1」のような置換も可能です。")
                    Text("置換は全発話にまとめて適用され、⌘Z で元に戻せます（⇧⌘Z でやり直し）。")
                    Text("発話の分割: 本文にカーソルを置いて ⌘↩。句点ごとに分けるなら ⌥⌘↩。統合は ⌥⌘↑ / ⌥⌘↓。")
                    Text("被った発言を足すには ⇧⌘↩ でこの発話の後に空の発話を挿入し、本文を入力。")
                    Text("複数まとめてつなげるには、行の左端の丸をクリックして選び ⌘J。")
                    Text("Tab / ⇧Tab で次／前の発話の本文へ。F8 で再生／一時停止、F7 / F9 で前／次の発話。")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

#if CLAUDE_TRANS
struct ProgressSheet: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let compressingOnly = model.progress?.stage == .compressing && model.transcript != nil
        VStack(alignment: .leading, spacing: 14) {
            Text(compressingOnly ? "音声を圧縮中" : "文字起こし中")
                .font(.headline)
            ProgressView(value: model.progress?.fraction ?? 0)
                .progressViewStyle(.linear)
            HStack {
                Text(model.progress?.stage.rawValue ?? "")
                Spacer()
                Text("\(Int((model.progress?.fraction ?? 0) * 100))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if let detail = model.progress?.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !compressingOnly {
                Text("初回は音声認識モデルと話者分離モデルのダウンロードで数分かかります。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            HStack {
                Spacer()
                Button("中止") { model.cancel() }
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}
#endif

struct ExportSheet: View {
    @EnvironmentObject private var model: AppModel
    @State private var format: ExportFormat = .docx

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("書き出し").font(.headline)
            Picker("形式", selection: $format) {
                ForEach(ExportFormat.allCases) { f in
                    Text(f.displayName).tag(f)
                }
            }
            .pickerStyle(.radioGroup)
            if format != .json && format != .csv {
                Divider()
                Toggle("タイムスタンプを入れる", isOn: $model.settings.exportTimestamps)
                Toggle("話者名を入れる", isOn: $model.settings.exportSpeakers)
                if format != .srt {
                    Toggle("同じ話者の連続発話を1段落にまとめる", isOn: $model.settings.exportMerge)
                }
            }
            HStack {
                Spacer()
                Button("キャンセル") { model.showExport = false }
                    .keyboardShortcut(.cancelAction)
                Button("書き出す…") {
                    model.showExport = false
                    model.export(format: format)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}

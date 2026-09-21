import SwiftUI
import CacaoTransCore

/// 「この音声について」: 背景と用語集をプロジェクトごとに入力する。
struct ProjectInfoSheet: View {
    @EnvironmentObject private var model: AppModel
    let mode: AppModel.InfoSheetMode

    @State private var context = ""
    @State private var glossary = ""

    private var title: String {
        switch mode {
        case .transcribe: return "この音声について（文字起こしの前に）"
        case .refine: return "この音声について（Claude 校正のやり直し）"
        case .edit: return "この音声について"
        }
    }

    private var confirmLabel: String {
        switch mode {
        case .transcribe: return "文字起こしを開始"
        case .refine: return "校正を実行"
        case .edit: return "保存"
        }
    }

    private var fileName: String {
        model.transcript?.sourceFileName ?? model.audioURL?.lastPathComponent ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            if !fileName.isEmpty {
                Label(fileName, systemImage: "waveform")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("背景（インタビュー・会議の目的、話し手の立場、時代や場所など）")
                    .font(.subheadline.weight(.medium))
                TextEditor(text: $context)
                    .font(.body)
                    .frame(height: 96)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                Text("例: 1945年前後の従軍体験の聞き取り。語り手は元兵士の鈴木、聞き手は郷土史研究者の山田。軍隊用語と地名が多い。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("用語集（1行に1つ。人名・地名・専門用語をこの表記に統一する）")
                    .font(.subheadline.weight(.medium))
                TextEditor(text: $glossary)
                    .font(.body)
                    .frame(height: 160)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                Text("例: 鈴木 太郎（すずき・たろう）: 語り手 ／ 山田: 聞き手 ／ ハルピン: 地名")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if mode != .edit {
                Text("この内容は Claude の校正にだけ使われ、プロジェクト（.ccot）に保存されます。音声認識そのものには影響しません。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            HStack {
                if mode == .transcribe {
                    Button("設定の初期値に戻す") {
                        context = model.settings.context
                        glossary = model.settings.glossary
                    }
                    .controlSize(.small)
                }
                Spacer()
                Button("キャンセル") { model.infoSheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button(confirmLabel) { model.confirmProjectInfo(context: context, glossary: glossary) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 600)
        .onAppear {
            let d = model.infoDefaults
            context = d.context
            glossary = d.glossary
        }
    }
}

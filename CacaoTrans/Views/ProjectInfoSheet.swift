import SwiftUI
import CacaoTransCore

/// 「この音声について」: 背景と用語集をプロジェクトごとに入力する。
/// 文字起こし前は「共通（初期値として保存）」＋「この音声だけの追記」の2段で、似た音声を続けて処理しやすくする。
struct ProjectInfoSheet: View {
    @EnvironmentObject private var model: AppModel
    let mode: AppModel.InfoSheetMode

    // transcribe モード: 共通 + 追記
    @State private var baseContext = ""
    @State private var extraContext = ""
    @State private var baseGlossary = ""
    @State private var extraGlossary = ""
    // refine / edit モード: まとめて1つ
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

            if mode == .transcribe {
                splitEditors
            } else {
                singleEditors
            }

            HStack {
                if mode == .transcribe {
                    Button("共通の内容を設定の値に戻す") {
                        baseContext = model.settings.context
                        baseGlossary = model.settings.glossary
                    }
                    .controlSize(.small)
                }
                Spacer()
                Button("キャンセル") { model.infoSheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button(confirmLabel) { confirm() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 640)
        .onAppear(perform: load)
    }

    // MARK: - transcribe: 共通 + 追記

    private var splitEditors: some View {
        VStack(alignment: .leading, spacing: 12) {
            editor("共通の背景（すべての音声に共通。開始すると初期値として保存されます）",
                   text: $baseContext, height: 64,
                   hint: "例: 1945年前後の従軍体験の聞き取り。聞き手は郷土史研究者の山田。軍隊用語と地名が多い。")
            editor("この音声だけの背景（追記）",
                   text: $extraContext, height: 64,
                   hint: "例: 語り手は元兵士の鈴木。ハルピンでの体験が中心。")
            editor("共通の用語集（1行に1つ。開始すると初期値として保存されます）",
                   text: $baseGlossary, height: 104,
                   hint: "例: 山田: 聞き手 ／ ハルピン: 地名")
            editor("この音声だけの用語集（追記）",
                   text: $extraGlossary, height: 80,
                   hint: "例: 鈴木 太郎（すずき・たろう）: 語り手")
            Text("Claude には共通と追記をつなげて渡し、その内容がプロジェクト（.ccot）に保存されます。音声認識そのものには影響しません。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - refine / edit: まとめて1つ

    private var singleEditors: some View {
        VStack(alignment: .leading, spacing: 12) {
            editor("背景（インタビュー・会議の目的、話し手の立場、時代や場所など）",
                   text: $context, height: 96,
                   hint: "例: 1945年前後の従軍体験の聞き取り。語り手は元兵士の鈴木、聞き手は郷土史研究者の山田。軍隊用語と地名が多い。")
            editor("用語集（1行に1つ。人名・地名・専門用語をこの表記に統一する）",
                   text: $glossary, height: 160,
                   hint: "例: 鈴木 太郎（すずき・たろう）: 語り手 ／ 山田: 聞き手 ／ ハルピン: 地名")
            if mode == .refine {
                Text("この内容は Claude の校正にだけ使われ、プロジェクト（.ccot）に保存されます。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func editor(_ label: String, text: Binding<String>, height: CGFloat, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.subheadline.weight(.medium))
            TextEditor(text: text)
                .font(.body)
                .frame(height: height)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            Text(hint).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Load / confirm

    private func load() {
        let d = model.infoDefaults
        if mode == .transcribe {
            baseContext = model.settings.context
            baseGlossary = model.settings.glossary
            extraContext = Self.remainder(of: d.context, after: baseContext)
            extraGlossary = Self.remainder(of: d.glossary, after: baseGlossary)
        } else {
            context = d.context
            glossary = d.glossary
        }
    }

    private func confirm() {
        if mode == .transcribe {
            let bc = baseContext.trimmingCharacters(in: .whitespacesAndNewlines)
            let bg = baseGlossary.trimmingCharacters(in: .whitespacesAndNewlines)
            if model.settings.context != bc { model.settings.context = bc }
            if model.settings.glossary != bg { model.settings.glossary = bg }
            model.confirmProjectInfo(context: Self.combine(bc, extraContext), glossary: Self.combine(bg, extraGlossary))
        } else {
            model.confirmProjectInfo(context: context, glossary: glossary)
        }
    }

    static func combine(_ base: String, _ extra: String) -> String {
        [base, extra.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// 既存の（共通＋追記をつなげた）文から共通部分を除いて追記だけを取り出す。
    static func remainder(of combined: String, after base: String) -> String {
        let c = combined.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if b.isEmpty { return c }
        if c == b { return "" }
        if c.hasPrefix(b) { return String(c.dropFirst(b.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
        return c
    }
}

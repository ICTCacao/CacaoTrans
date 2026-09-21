import SwiftUI
import CacaoTransCore

struct TranscriptListView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var playback: PlaybackController
    @FocusState private var focusedSegment: Int?

    var body: some View {
        let segments = model.transcript?.segments ?? []
        let matching = model.showOnlyMatches && !model.findQuery.isEmpty ? model.matchingSegmentIDs : nil
        let visible = matching.map { ids in segments.filter { ids.contains($0.id) } } ?? segments

        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                if !model.selectedSegmentIDs.isEmpty {
                    SelectionBar()
                }
            List(selection: $model.selectedSegmentIDs) {
                ForEach(visible) { seg in
                    SegmentRow(segment: seg,
                               highlighted: matching == nil && !model.findQuery.isEmpty && model.matchingSegmentIDs.contains(seg.id),
                               focus: $focusedSegment)
                        .id(seg.id)
                        .listRowSeparator(.visible)
                }
            }
            .listStyle(.plain)
            .onChange(of: focusedSegment) { _, id in
                model.focusedSegmentID = id
            }
            .onChange(of: model.focusedSegmentID) { _, id in
                guard let id, id != focusedSegment else { return }
                withAnimation { proxy.scrollTo(id, anchor: .center) }
                DispatchQueue.main.async { focusedSegment = id }
            }
            .onChange(of: playback.playingSegmentID) { _, id in
                guard let id, playback.isPlaying else { return }
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            }
            .overlay(alignment: .bottom) {
                if let msg = model.lastReplaceMessage {
                    Text(msg)
                        .font(.callout)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task(id: msg) {
                            try? await Task.sleep(nanoseconds: 3_000_000_000)
                            if model.lastReplaceMessage == msg { model.lastReplaceMessage = nil }
                        }
                }
            }
            .animation(.default, value: model.lastReplaceMessage)
            }
        }
    }
}

/// 複数選択中に上部に出る操作バー。
struct SelectionBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Text("\(model.selectedSegmentIDs.count) 件選択中")
                .font(.callout.weight(.semibold))
            Button("つなげる（⌘J）") { model.mergeSelected() }
                .disabled(model.selectedSegmentIDs.count < 2)
                .buttonStyle(.borderedProminent)
            Menu("話者をまとめて変更") {
                ForEach(model.allSpeakers, id: \.self) { label in
                    Button(model.transcript?.displayName(for: label) ?? label) { model.setSpeakerForSelected(label) }
                }
            }
            .fixedSize()
            Button("削除", role: .destructive) { model.deleteSelected() }
            Spacer()
            Button("選択解除") { model.clearSelection() }
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(Color.accentColor.opacity(0.10))
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct SegmentRow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var playback: PlaybackController
    let segment: TranscriptSegment
    let highlighted: Bool
    let focus: FocusState<Int?>.Binding

    private var isCurrent: Bool { playback.playingSegmentID == segment.id }
    private var isSelected: Bool { model.selectedSegmentIDs.contains(segment.id) }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                model.toggleSelection(segment.id)
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .buttonStyle(.plain)
            .help("選択（複数選んでつなげる・話者変更・削除）")
            .padding(.top, 4)

            Button {
                playback.play(segment: segment)
            } label: {
                Image(systemName: isCurrent && playback.isPlaying ? "pause.circle.fill" : "play.circle")
                    .font(.title2)
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!playback.isLoaded)
            .help(playback.isLoaded ? "この発話を再生" : "音声ファイルが見つかりません（再生メニューから指定）")
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                Text(Transcript.formatTime(segment.start, alwaysHours: true))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Menu {
                    ForEach(model.allSpeakers, id: \.self) { label in
                        Button {
                            model.setSpeaker(label, for: segment.id)
                        } label: {
                            Text(model.transcript?.displayName(for: label) ?? label)
                        }
                    }
                    Divider()
                    Button("新しい話者を割り当て") {
                        let label = model.addSpeaker()
                        model.setSpeaker(label, for: segment.id)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Circle().fill(SpeakerColor.color(for: segment.speaker)).frame(width: 8, height: 8)
                        Text(model.transcript?.displayName(for: segment.speaker) ?? segment.speaker)
                            .lineLimit(1)
                    }
                    .font(.callout.weight(.medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .frame(width: 110, alignment: .leading)

            TextField("（発話を入力）", text: model.binding(for: segment.id), axis: .vertical)
                .focused(focus, equals: segment.id)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...20)
                .padding(6)
                .background(highlighted ? Color.yellow.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 6))

            if let original = segment.originalText, original != segment.text {
                Image(systemName: "sparkles")
                    .foregroundStyle(.secondary)
                    .help("Claude 校正前: \(original)")
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(isCurrent ? Color.accentColor.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            Button("この発話を再生") { playback.play(segment: segment) }
                .disabled(!playback.isLoaded)
            Divider()
            Button("カーソル位置で分割（⌘↩）") {
                if model.focusedSegmentID == segment.id {
                    model.splitFocusedSegmentAtCursor()
                } else {
                    model.lastReplaceMessage = "本文をクリックして分けたい位置にカーソルを置き、⌘↩ を押してください"
                }
            }
            Button("句点（。？！）で分割") { model.splitSegmentAtSentences(segment.id) }
            Divider()
            Button("この後に発話を挿入（⇧⌘↩）") { model.insertSegment(relativeTo: segment.id, after: true) }
            Button("この前に発話を挿入") { model.insertSegment(relativeTo: segment.id, after: false) }
            Divider()
            if model.selectedSegmentIDs.count >= 2 {
                Button("選択した \(model.selectedSegmentIDs.count) 件をつなげる（⌘J）") { model.mergeSelected() }
            }
            Button("前の発話とつなげる") { model.mergeSegmentWithPrevious(segment.id) }
            Button("次の発話とつなげる") { model.mergeSegmentWithNext(segment.id) }
            Divider()
            Button("この発話を削除", role: .destructive) { model.deleteSegment(segment.id) }
            if let original = segment.originalText {
                Divider()
                Button("校正前の文に戻す") { model.binding(for: segment.id).wrappedValue = original }
            }
        }
    }
}

import SwiftUI
import CacaoTransCore

/// 画面下の再生バー。
struct PlayerBar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var playback: PlaybackController

    var body: some View {
        HStack(spacing: 14) {
            if playback.isLoaded {
                transport
                timeline
                Divider().frame(height: 22)
                optionControls
            } else {
                Label("音声ファイルが見つからないため再生できません", systemImage: "speaker.slash")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("音声フォルダを設定…") { model.chooseAudioFolder() }
                    .help("音声の置き場所（既定: 書類/CacaoTrans）。現在: \(model.audioFolder.displayPath)")
                Button("音声ファイルを指定…") { model.relinkAudio() }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var transport: some View {
        HStack(spacing: 6) {
            Button { playback.playPrevious() } label: { Image(systemName: "backward.end.fill") }
                .help("前の発話（F7 / ⌘↑）")
            Button { playback.togglePlayPause() } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 18, height: 16)
            }
            .help("再生 / 一時停止（F8）")
            Button { playback.playNext() } label: { Image(systemName: "forward.end.fill") }
                .help("次の発話（F9 / ⌘↓）")
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }

    private var timeline: some View {
        HStack(spacing: 8) {
            Text(Transcript.formatTime(playback.currentTime, alwaysHours: playback.duration >= 3600))
                .font(.system(.caption, design: .monospaced))
                .frame(width: 56, alignment: .trailing)
            Slider(
                value: Binding(get: { playback.currentTime }, set: { playback.seek(to: $0) }),
                in: 0...max(1, playback.duration)
            )
            Text(Transcript.formatTime(playback.duration, alwaysHours: playback.duration >= 3600))
                .font(.system(.caption, design: .monospaced))
                .frame(width: 56, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    private var optionControls: some View {
        HStack(spacing: 12) {
            Picker("速度", selection: $playback.rate) {
                ForEach(PlaybackController.rates, id: \.self) { r in
                    Text(r == 1 ? "1×" : String(format: "%.2g×", r)).tag(r)
                }
            }
            .frame(width: 100)
            .help("再生速度")

            Toggle(isOn: $playback.continuous) {
                Text("連続再生")
                    .fixedSize()
            }
            .toggleStyle(.checkbox)
            .fixedSize()
            .help("オンにすると発話の終わりで止まらず次へ続けます（既定はオフ＝1発話だけ再生）")

            Picker("話者", selection: $playback.speakerFilter) {
                Text("全員").tag(String?.none)
                ForEach(model.allSpeakers, id: \.self) { label in
                    Text(model.transcript?.displayName(for: label) ?? label).tag(Optional(label))
                }
            }
            .frame(width: 140)
            .help("連続再生・次／前の発話で、この話者の発話だけをたどります")
        }
        .controlSize(.small)
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
    }
}

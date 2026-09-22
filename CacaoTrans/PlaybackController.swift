import Foundation
import AVFoundation
import MediaPlayer
import CacaoTransCore

/// 元の音声を発話単位で再生する。
@MainActor
final class PlaybackController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isLoaded = false
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var playingSegmentID: Int?
    @Published var rate: Float = 1.0 {
        didSet { player?.rate = rate }
    }
    /// 発話の終わりで止めず、次の発話へ続けて再生する。
    @Published var continuous = false
    /// 指定した話者の発話だけ再生する（nil は全員）。
    @Published var speakerFilter: String?

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var accessedURL: URL?
    private var segmentsProvider: () -> [TranscriptSegment] = { [] }
    /// 単発再生のときの停止位置
    private var stopAt: Double?
    /// Tab やクリックで本文に入った発話。次の再生開始はここから。
    private var cuedSegmentID: Int?
    /// 発話の再生を始めたとき（F8 で次の発話へ進んだときを含む）に呼ばれる。
    var onStartSegment: ((Int) -> Void)?

    static let rates: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]

    func setSegmentsProvider(_ provider: @escaping () -> [TranscriptSegment]) {
        segmentsProvider = provider
    }

    // MARK: - メディアキー（キーボードの再生／一時停止・次・前）

    private var remoteCommandsInstalled = false

    private func installRemoteCommands() {
        guard !remoteCommandsInstalled else { return }
        remoteCommandsInstalled = true
        let center = MPRemoteCommandCenter.shared()
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.isPlaying == false { self?.togglePlayPause() } }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playNext() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playPrevious() }
            return .success
        }
    }

    /// 「今再生中」情報を更新する。これがないとメディアキーがこのアプリに届かない。
    private func updateNowPlaying(title: String? = nil) {
        let center = MPNowPlayingInfoCenter.default()
        var info = center.nowPlayingInfo ?? [:]
        if let title { info[MPMediaItemPropertyTitle] = title }
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? Double(rate) : 0
        center.nowPlayingInfo = info
        center.playbackState = isLoaded ? (isPlaying ? .playing : .paused) : .stopped
    }

    // MARK: - Load

    func load(url: URL, securityScoped: Bool) throws {
        unload()
        if securityScoped, url.startAccessingSecurityScopedResource() {
            accessedURL = url
        }
        let p = try AVAudioPlayer(contentsOf: url)
        p.enableRate = true
        p.rate = rate
        p.delegate = self
        p.prepareToPlay()
        player = p
        duration = p.duration
        currentTime = 0
        isLoaded = true
        installRemoteCommands()
        updateNowPlaying(title: url.lastPathComponent)
    }

    func unload() {
        stopTimer()
        player?.stop()
        player = nil
        if let accessedURL {
            accessedURL.stopAccessingSecurityScopedResource()
            self.accessedURL = nil
        }
        isLoaded = false
        isPlaying = false
        playingSegmentID = nil
        currentTime = 0
        duration = 0
        updateNowPlaying()
    }

    // MARK: - Transport

    func play(segment: TranscriptSegment) {
        guard let player else { return }
        if playingSegmentID == segment.id, isPlaying {
            pause()
            return
        }
        cuedSegmentID = nil
        playingSegmentID = segment.id
        stopAt = continuous ? nil : max(segment.end, segment.start + 0.3)
        player.currentTime = max(0, segment.start)
        player.rate = rate
        player.play()
        isPlaying = true
        startTimer()
        updateNowPlaying()
        onStartSegment?(segment.id)
    }

    /// 発話を頭から再生し直す（再生中でも止めずに頭へ戻す）。同じ発話を何度でも聞き直すため。
    func replay(segment: TranscriptSegment) {
        guard player != nil else { return }
        if isPlaying { pause() }
        playingSegmentID = nil
        play(segment: segment)
    }

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            pause()
        } else {
            // 本文に入っている発話があればそこから再生する
            if let id = cuedSegmentID, let seg = segmentsProvider().first(where: { $0.id == id }) {
                cuedSegmentID = nil
                play(segment: seg)
                return
            }
            let segments = segmentsProvider()
            // 再生対象の発話を聞き終えているなら、次の発話へ。次がなければ最初から
            if let id = playingSegmentID, let idx = segments.firstIndex(where: { $0.id == id }),
               player.currentTime >= segments[idx].end - 0.05 {
                if let next = segments[(idx + 1)...].first(where: matchesFilter) {
                    play(segment: next)
                } else if let first = segments.first(where: matchesFilter) {
                    play(segment: first)
                }
                return
            }
            if playingSegmentID == nil, let first = segments.first(where: matchesFilter) {
                play(segment: first)
                return
            }
            player.play()
            isPlaying = true
            startTimer()
            updateNowPlaying()
            if let id = playingSegmentID { onStartSegment?(id) }
        }
    }

    /// 本文に入った発話を再生対象にする（再生はしない）。再生中でなければ位置もその頭に合わせる。
    func cue(segment: TranscriptSegment) {
        guard let player else { return }
        cuedSegmentID = segment.id
        guard !isPlaying else { return }
        playingSegmentID = segment.id
        player.currentTime = max(0, segment.start)
        currentTime = player.currentTime
        stopAt = continuous ? nil : max(segment.end, segment.start + 0.3)
        updateNowPlaying()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
        updateNowPlaying()
    }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        isPlaying = false
        playingSegmentID = nil
        currentTime = 0
        stopTimer()
    }

    func seek(to time: Double) {
        guard let player else { return }
        player.currentTime = max(0, min(time, duration))
        currentTime = player.currentTime
        playingSegmentID = segment(at: currentTime)?.id
        stopAt = nil
    }

    func playNext() { step(1) }
    func playPrevious() { step(-1) }

    private func step(_ delta: Int) {
        let segments = segmentsProvider().filter(matchesFilter)
        guard !segments.isEmpty else { return }
        let currentIndex: Int
        if let id = playingSegmentID, let i = segments.firstIndex(where: { $0.id == id }) {
            currentIndex = i
        } else {
            currentIndex = segments.firstIndex(where: { $0.start >= currentTime }) ?? 0
        }
        let next = max(0, min(segments.count - 1, currentIndex + delta))
        play(segment: segments[next])
    }

    // MARK: - Internals

    private func matchesFilter(_ seg: TranscriptSegment) -> Bool {
        speakerFilter == nil || seg.speaker == speakerFilter
    }

    private func segment(at time: Double) -> TranscriptSegment? {
        let segments = segmentsProvider()
        return segments.last(where: { $0.start <= time && time < $0.end + 0.3 })
            ?? segments.first(where: { $0.start > time })
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let player, isPlaying else { return }
        let t = player.currentTime
        if abs(t - currentTime) >= 0.05 { currentTime = t }

        if let stopAt, currentTime >= stopAt {
            pause()
            return
        }

        let segments = segmentsProvider()
        guard let id = playingSegmentID, let idx = segments.firstIndex(where: { $0.id == id }) else {
            playingSegmentID = segment(at: currentTime)?.id
            return
        }
        let current = segments[idx]
        if currentTime >= current.end {
            // 次の発話へ
            if let next = segments[(idx + 1)...].first(where: matchesFilter) {
                playingSegmentID = next.id
                if next.start > currentTime + 0.25 || next.start < currentTime - 0.25 {
                    player.currentTime = next.start
                }
                stopAt = continuous ? nil : max(next.end, next.start + 0.3)
                if !continuous { pause(); playingSegmentID = next.id; player.currentTime = next.start; currentTime = next.start }
            } else {
                finishPlayback()
            }
        }
    }

    /// 最後の発話（または音声の末尾）まで再生し切った。位置を先頭に戻し、次の F8 は最初の発話から再生する。
    private func finishPlayback() {
        stopTimer()
        player?.pause()
        player?.currentTime = 0
        currentTime = 0
        isPlaying = false
        stopAt = nil
        playingSegmentID = nil
        cuedSegmentID = nil
        updateNowPlaying()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.finishPlayback() }
    }
}

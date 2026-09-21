import Foundation
import AVFoundation
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

    static let rates: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]

    func setSegmentsProvider(_ provider: @escaping () -> [TranscriptSegment]) {
        segmentsProvider = provider
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
    }

    // MARK: - Transport

    func play(segment: TranscriptSegment) {
        guard let player else { return }
        if playingSegmentID == segment.id, isPlaying {
            pause()
            return
        }
        playingSegmentID = segment.id
        stopAt = continuous ? nil : max(segment.end, segment.start + 0.3)
        player.currentTime = max(0, segment.start)
        player.rate = rate
        player.play()
        isPlaying = true
        startTimer()
    }

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            pause()
        } else {
            if playingSegmentID == nil, let first = segmentsProvider().first(where: matchesFilter) {
                play(segment: first)
                return
            }
            player.play()
            isPlaying = true
            startTimer()
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
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
                pause()
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.stopTimer()
        }
    }
}

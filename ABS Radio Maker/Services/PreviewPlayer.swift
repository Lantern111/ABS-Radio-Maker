import AVFoundation
import Observation

/// Plays the edited sound for the preview. The picture follows `currentTime`.
@MainActor @Observable final class PreviewPlayer {
    private(set) var isPlaying = false
    private(set) var duration: Double = 0

    @ObservationIgnored private var player: AVAudioPlayer?
    /// Where playback is while paused, so scrubbing works before anything is loaded.
    @ObservationIgnored private var pausedTime: Double = 0
    @ObservationIgnored private var endObserver: Timer?

    /// Changes whenever the position jumps, so a paused preview redraws.
    private(set) var seekRevision = 0

    var currentTime: Double {
        if let player, isPlaying { return player.currentTime }
        return pausedTime
    }

    func load(_ url: URL) {
        let keepTime = currentTime
        stop()
        player = try? AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
        duration = player?.duration ?? 0
        seek(to: min(keepTime, duration))
    }

    func unload() {
        stop()
        player = nil
        duration = 0
        pausedTime = 0
        seekRevision += 1
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let player else { return }
        if pausedTime >= duration - 0.05 { pausedTime = 0 }
        player.currentTime = pausedTime
        player.play()
        isPlaying = true
        // AVAudioPlayer's delegate is an Objective-C protocol; checking now and then is simpler.
        endObserver = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let player = self.player, self.isPlaying, !player.isPlaying else { return }
                self.pausedTime = self.duration
                self.stop()
            }
        }
    }

    func pause() {
        guard isPlaying else { return }
        pausedTime = player?.currentTime ?? pausedTime
        stop()
    }

    func seek(to time: Double) {
        pausedTime = min(max(time, 0), duration)
        player?.currentTime = pausedTime
        seekRevision += 1
    }

    private func stop() {
        player?.pause()
        isPlaying = false
        endObserver?.invalidate()
        endObserver = nil
        seekRevision += 1
    }
}

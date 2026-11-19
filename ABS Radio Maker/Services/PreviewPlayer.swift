import AVFoundation
import Observation

/// Plays the edited sound for the preview. The picture and the timeline follow `time`.
@MainActor @Observable final class PreviewPlayer {
    private(set) var isPlaying = false
    private(set) var duration: Double = 0
    /// Where playback is, in seconds. Updated 30 times a second while playing, so anything that shows it moves along.
    private(set) var time: Double = 0

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var clock: Timer?

    func load(_ url: URL) {
        let keepTime = time
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
        time = 0
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let player else { return }
        if time >= duration - 0.05 { time = 0 }
        player.currentTime = time
        player.play()
        isPlaying = true
        let clock = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // The common mode keeps it running while a slider or the timeline is being dragged.
        RunLoop.main.add(clock, forMode: .common)
        self.clock = clock
    }

    func pause() {
        guard isPlaying else { return }
        time = player?.currentTime ?? time
        stop()
    }

    func seek(to newTime: Double) {
        time = min(max(newTime, 0), duration)
        player?.currentTime = time
    }

    private func tick() {
        guard let player, isPlaying else { return }
        if player.isPlaying {
            time = player.currentTime
        } else {
            // Reached the end.
            time = duration
            stop()
        }
    }

    private func stop() {
        player?.pause()
        isPlaying = false
        clock?.invalidate()
        clock = nil
    }
}

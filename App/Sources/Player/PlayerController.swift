import AppKit
import AVFoundation
import Observation

/// AVPlayer wrapper exposing observable state for the custom controls (§3).
@MainActor
@Observable
final class PlayerController {
    static let rates: [Float] = [3, 2, 1.5, 1.25, 1, 0.75, 0.5]

    let player = AVPlayer()
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    private(set) var rate: Float = 1
    private(set) var volume: Float = 1
    private(set) var isMuted = false
    private(set) var isSeeking = false

    /// Called on every time tick (20 Hz) with the current time, except while a seek is in flight.
    @ObservationIgnored var onTick: (@MainActor (Double) -> Void)?
    /// Called when the user-visible playback position jumps (seek finished).
    @ObservationIgnored var onSeekFinished: (@MainActor (Double) -> Void)?

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var seekGeneration = 0

    init() {
        player.actionAtItemEnd = .pause
    }

    func load(url: URL, knownDuration: Double, rate: Float, volume: Float) {
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .spectral
        player.replaceCurrentItem(with: item)
        self.duration = knownDuration
        setRate(rate)
        setVolume(volume)

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] time in
            let seconds = time.seconds
            MainActor.assumeIsolated {
                self?.tick(seconds)
            }
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying != playing else { return }
                self.isPlaying = playing
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isPlaying = false
            }
        }
        Task { [weak self] in
            guard let loaded = try? await asset.load(.duration) else { return }
            let seconds = loaded.seconds
            guard seconds.isFinite, seconds > 0 else { return }
            self?.duration = seconds
        }
    }

    private func tick(_ t: Double) {
        guard !isSeeking, t.isFinite else { return }
        currentTime = t
        onTick?(t)
    }

    // MARK: Transport

    func play() {
        guard player.currentItem != nil else { return }
        if duration > 0 && currentTime >= duration - 0.05 {
            seek(to: 0)
        }
        player.playImmediately(atRate: rate)
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    /// Exact seek by default; `precise: false` while scrubbing.
    func seek(to t: Double, precise: Bool = true) {
        let clamped = max(0, t.isFinite ? t : 0)
        let target = duration > 0 ? min(clamped, duration) : clamped
        currentTime = target
        isSeeking = true
        seekGeneration += 1
        let generation = seekGeneration
        let tolerance = precise ? CMTime.zero : CMTime(value: 1, timescale: 4)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, generation == self.seekGeneration else { return }
                self.isSeeking = false
                self.onSeekFinished?(target)
            }
        }
    }

    func skip(by delta: Double) {
        seek(to: currentTime + delta)
    }

    func setRate(_ r: Float) {
        rate = r
        player.defaultRate = r
        if isPlaying { player.rate = r }
    }

    func setVolume(_ v: Float) {
        volume = min(1, max(0, v))
        player.volume = volume
        if volume > 0 && isMuted {
            isMuted = false
            player.isMuted = false
        }
    }

    func toggleMute() {
        isMuted.toggle()
        player.isMuted = isMuted
    }

    func teardown() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        onTick = nil
        onSeekFinished = nil
        player.replaceCurrentItem(with: nil)
        isPlaying = false
    }
}

// MARK: - Media inspection & thumbnails

enum MediaInspector {
    struct Info {
        var duration: Double
        var hasVideo: Bool
    }

    static func inspect(url: URL) async throws -> Info {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let seconds = duration.seconds
        return Info(duration: seconds.isFinite ? seconds : 0, hasVideo: !tracks.isEmpty)
    }

    /// JPEG of the frame at 10% of the duration, for list thumbnails (§9.5).
    static func coverJPEG(url: URL, duration: Double) async -> Data? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 270)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 1)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 1)
        let time = CMTime(seconds: max(0, duration * 0.1), preferredTimescale: 600)
        guard let result = try? await generator.image(at: time) else { return nil }
        let rep = NSBitmapImageRep(cgImage: result.image)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}

/// On-demand frames for the progress-bar hover preview, cached in 2-second buckets (§3.2).
@MainActor
@Observable
final class ThumbnailProvider {
    private(set) var image: NSImage?
    private(set) var bucket: Int = -1

    @ObservationIgnored private let generator: AVAssetImageGenerator
    @ObservationIgnored private var cache: [Int: NSImage] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?

    init(url: URL) {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 320, height: 180)
        gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 1)
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 1)
        generator = gen
    }

    func request(time: Double) {
        let b = max(0, Int(time / 2))
        guard b != bucket else { return }
        bucket = b
        if let cached = cache[b] {
            image = cached
            return
        }
        task?.cancel()
        let generator = self.generator
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000)
            if Task.isCancelled { return }
            let t = CMTime(seconds: Double(b) * 2 + 1, preferredTimescale: 600)
            guard let result = try? await generator.image(at: t) else { return }
            let img = NSImage(cgImage: result.image, size: .zero)
            guard let self else { return }
            self.cache[b] = img
            if self.bucket == b { self.image = img }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        bucket = -1
    }
}

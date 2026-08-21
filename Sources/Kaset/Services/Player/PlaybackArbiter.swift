import Foundation
import Observation

// MARK: - PlaybackArbiter

/// Ensures exactly one audio source plays at a time: starting YouTube video
/// playback pauses music, and starting music pauses video.
///
/// `PlayerService` (music) is intentionally not modified — KasetApp calls
/// `musicDidStartPlaying()` from its existing `onChange(of: isPlaying)`
/// hook, and `YouTubePlayerService` invokes `playbackWillStart` before any
/// video playback begins.
///
/// It also owns the one policy that applies to whichever source is playing:
/// losing the audio output device pauses playback (see
/// ``outputRouteDidDisappear()``).
@MainActor
@Observable
final class PlaybackArbiter {
    /// The source that most recently started playback. Media keys route here.
    private(set) var activeSource: AppSource = .music

    private let playerService: PlayerService
    private let youtubePlayerService: YouTubePlayerService

    /// User preference gate for ``outputRouteDidDisappear()``. Injected rather
    /// than read from `SettingsManager.shared` so tests configure a single
    /// instance instead of mutating the shared singleton, which races across
    /// suites that run in parallel.
    private let pausesOnOutputDeviceDisconnect: @MainActor () -> Bool
    private let logger = DiagnosticsLogger.player

    init(
        playerService: PlayerService,
        youtubePlayerService: YouTubePlayerService,
        pausesOnOutputDeviceDisconnect: @escaping @MainActor () -> Bool = {
            SettingsManager.shared.pauseOnOutputDeviceDisconnect
        }
    ) {
        self.playerService = playerService
        self.youtubePlayerService = youtubePlayerService
        self.pausesOnOutputDeviceDisconnect = pausesOnOutputDeviceDisconnect

        youtubePlayerService.playbackWillStart = { [weak self] in
            self?.videoWillStartPlaying()
        }
    }

    /// Video playback is about to start — pause music.
    func videoWillStartPlaying() {
        self.activeSource = .video
        let intent = self.playerService.beginMusicPlaybackIntent()

        let hasActiveOrPendingMusic = self.playerService.isPlaying
            || self.playerService.state == .loading
            || self.playerService.isAwaitingPlaybackConfirmation
            || self.playerService.pendingPlayVideoId != nil
        guard hasActiveOrPendingMusic else { return }
        self.logger.info("Arbiter: pausing music for video playback")
        Task {
            await self.playerService.pause(intent: intent)
        }
    }

    /// Music playback started — pause video (call from KasetApp's existing
    /// `onChange(of: playerService.isPlaying)` hook).
    func musicDidStartPlaying() {
        guard self.activeSource != .music else { return }
        self.activeSource = .music

        guard self.youtubePlayerService.isPlaying else { return }
        self.logger.info("Arbiter: pausing video for music playback")
        self.youtubePlayerService.pause()
    }

    /// The audio output device playback was using disappeared — headphones
    /// unplugged, AirPods disconnected, an interface pulled out. Whatever is
    /// playing has been moved to a speaker the user did not choose, so pause
    /// it. Ownership of the media keys is unaffected: pausing is not a source
    /// switch.
    ///
    /// Deliberately not called for a switch to a device that is still
    /// attached: choosing a different output, or connecting headphones, is not
    /// a reason to stop the music.
    func outputRouteDidDisappear() {
        guard self.pausesOnOutputDeviceDisconnect() else { return }

        if self.youtubePlayerService.isPlaying {
            self.logger.info("Arbiter: pausing video after losing the output device")
            self.youtubePlayerService.pause()
        }

        // Only claim a music intent when there is playing music to pause:
        // beginning one supersedes any in-flight music request, and a device
        // disconnect must not cancel a load the user just started.
        guard self.playerService.isPlaying else { return }
        self.logger.info("Arbiter: pausing music after losing the output device")
        let intent = self.playerService.beginMusicPlaybackIntent()
        Task {
            await self.playerService.pause(intent: intent)
        }
    }

    /// Whether media keys should currently control the YouTube video player.
    var routesMediaKeysToVideo: Bool {
        self.activeSource == .video && self.youtubePlayerService.currentVideo != nil
    }
}

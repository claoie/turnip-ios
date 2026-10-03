import SwiftUI

/// The capsule chrome behind every bare-`AVPlayer` transport control in the app —
/// `VideoScrubBar`'s track-plus-buttons bar, and `ClipEditorView`'s buttons-only
/// pill. The two had copy-pasted the same font/padding/background; this is the one
/// definition both build on. Content (which buttons, how they're spaced) stays with
/// the caller, since a scrub track and a bare button pair aren't the same layout.
struct PlaybackControlsPill<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .font(.body)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Capsule().fill(.black.opacity(0.4)))
    }
}

/// A play/pause glyph button for a `PlaybackControlsPill`, styled and labeled
/// consistently wherever bare-player transport controls appear.
struct PlayPauseButton: View {
    let isPlaying: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .foregroundStyle(.white)
                .playbackControlTouchTarget()
        }
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
        .accessibilityIdentifier("playback-play-pause")
    }
}

/// A mute glyph button for a `PlaybackControlsPill`, styled and labeled consistently
/// wherever bare-player transport controls appear.
struct MuteButton: View {
    let isMuted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .foregroundStyle(.white)
                .playbackControlTouchTarget()
        }
        .accessibilityLabel(isMuted ? "Unmute" : "Mute")
        .accessibilityIdentifier("playback-mute")
    }
}

private extension View {
    /// Brings a bare glyph up to the 44 pt touch-target and focus-ring floor without changing
    /// what the pill lays out. Applied to the glyph inside the `Button`, so it is part of that
    /// button's own hit-testing region — the placement `ScrimIconButton` documents. An inset
    /// rather than a `frame`: a body-sized glyph is about 20 pt and the pill's padding sits
    /// outside the buttons, so a frame would stretch the capsule to 64 pt tall instead of
    /// growing the region a finger has to find.
    func playbackControlTouchTarget() -> some View {
        contentShape([.interaction, .accessibility], Rectangle().inset(by: -12))
    }
}

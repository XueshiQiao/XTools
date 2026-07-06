import SwiftUI

/// The Now Playing tool: shows which apps are currently playing audio to an
/// output device (the audio-output locks `coreaudiod` holds per client), and
/// lets you quit one to stop it.
///
/// Self-contained in `Sources/Tools/NowPlaying/`. Read-only scanner + on-demand
/// actions, so no app-lifetime background work (no `activate()`).
final class NowPlayingTool: XToolModule {

    let id = "now-playing"
    var title: String { L("tool.nowplaying.title") }
    let symbol = "waveform"
    let color = Color.pink

    private lazy var store = NowPlayingStore()

    func makeRootView() -> AnyView { AnyView(NowPlayingView(store: store)) }
}

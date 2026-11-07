import AVKit
import SwiftUI

@MainActor
private final class PushifyPaywallVideoModel: ObservableObject {
    @Published var player: AVPlayer?
    @Published var ready = false
    @Published var failed = false
    private var statusObservation: NSKeyValueObservation?

    func load(url: URL, autoPlay: Bool, muted: Bool) {
        guard player?.currentItem?.asset as? AVURLAsset == nil ||
                (player?.currentItem?.asset as? AVURLAsset)?.url != url else { return }
        stop()
        failed = false
        ready = false
        let item = AVPlayerItem(url: url)
        let next = AVPlayer(playerItem: item)
        next.isMuted = muted
        player = next
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak next] item, _ in
            DispatchQueue.main.async {
                guard let self, let next else { return }
                switch item.status {
                case .readyToPlay:
                    self.ready = true
                    if autoPlay { next.play() }
                case .failed:
                    self.failed = true
                    next.pause()
                default: break
                }
            }
        }
    }

    func fail() {
        failed = true
        ready = false
        player?.pause()
    }

    func stop() {
        statusObservation?.invalidate()
        statusObservation = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        ready = false
    }
}

struct PushifyPaywallVideo: View {
    let url: URL
    let posterURL: URL?
    let width: Double
    let height: Double
    let autoPlay: Bool
    let loops: Bool
    let muted: Bool
    let showsControls: Bool
    let fitMode: String
    let fixedHeight: CGFloat?

    @StateObject private var model = PushifyPaywallVideoModel()

    private var ratio: CGFloat { CGFloat(width / max(height, 1)) }

    var body: some View {
        ZStack {
            Color.black
            if !model.ready || model.failed {
                poster
            }
            if let player = model.player, !model.failed {
                PushifyPaywallPlayerController(
                    player: player,
                    showsControls: showsControls,
                    fitMode: fitMode
                )
                .opacity(model.ready ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: fixedHeight)
        .aspectRatio(fixedHeight == nil ? ratio : nil, contentMode: .fit)
        .clipped()
        .accessibilityElement(children: .contain)
        .task(id: url) { model.load(url: url, autoPlay: autoPlay, muted: muted) }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { note in
            guard let item = note.object as? AVPlayerItem, item === model.player?.currentItem else { return }
            guard loops, let player = model.player else { return }
            player.seek(to: .zero) { _ in player.play() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)) { note in
            guard let item = note.object as? AVPlayerItem, item === model.player?.currentItem else { return }
            model.fail()
        }
        .onDisappear { model.stop() }
    }

    @ViewBuilder private var poster: some View {
        if let posterURL {
            AsyncImage(url: posterURL) { image in image.resizable().scaledToFill() } placeholder: { placeholder }
                .clipped()
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            Color.black
            if model.failed {
                Image(systemName: "video.slash.fill").font(.title3).foregroundStyle(.white.opacity(0.8))
                    .accessibilityLabel("Video unavailable")
            } else {
                ProgressView().tint(.white).accessibilityLabel("Loading video")
            }
        }
    }
}

private struct PushifyPaywallPlayerController: UIViewControllerRepresentable {
    let player: AVPlayer
    let showsControls: Bool
    let fitMode: String

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = showsControls
        controller.videoGravity = fitMode == "fit" ? .resizeAspect : .resizeAspectFill
        controller.view.backgroundColor = .black
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
        controller.showsPlaybackControls = showsControls
        controller.videoGravity = fitMode == "fit" ? .resizeAspect : .resizeAspectFill
    }
}

import SwiftUI
import Lottie

struct PushifyLottieAnimation: UIViewRepresentable {
    let url: URL
    let autoPlay: Bool
    let loops: Bool
    let reduceMotion: Bool
    let fit: String
    let label: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.clipsToBounds = true
        let fallback = UILabel()
        fallback.text = "Animation unavailable"
        fallback.textAlignment = .center
        fallback.isHidden = true
        fallback.accessibilityLabel = "\(label) unavailable"
        context.coordinator.autoPlay = autoPlay
        context.coordinator.reduceMotion = reduceMotion
        let coordinator = context.coordinator
        let player = LottieAnimationView(url: url) { error in
            DispatchQueue.main.async {
                coordinator.fallback?.isHidden = error == nil
                coordinator.player?.isHidden = error != nil
                guard error == nil, let loaded = coordinator.player else { return }
                if coordinator.autoPlay && !coordinator.reduceMotion { loaded.play() }
                else { loaded.currentProgress = 0 }
            }
        }
        player.translatesAutoresizingMaskIntoConstraints = false
        fallback.translatesAutoresizingMaskIntoConstraints = false
        player.contentMode = fit == "fill" ? .scaleAspectFill : .scaleAspectFit
        player.loopMode = loops ? .loop : .playOnce
        player.accessibilityLabel = label
        player.isAccessibilityElement = true
        container.addSubview(player)
        container.addSubview(fallback)
        NSLayoutConstraint.activate([
            player.leadingAnchor.constraint(equalTo: container.leadingAnchor), player.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            player.topAnchor.constraint(equalTo: container.topAnchor), player.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            fallback.leadingAnchor.constraint(equalTo: container.leadingAnchor), fallback.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            fallback.topAnchor.constraint(equalTo: container.topAnchor), fallback.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        context.coordinator.player = player
        context.coordinator.fallback = fallback
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let player = context.coordinator.player else { return }
        context.coordinator.autoPlay = autoPlay
        context.coordinator.reduceMotion = reduceMotion
        player.contentMode = fit == "fill" ? .scaleAspectFill : .scaleAspectFit
        player.loopMode = loops ? .loop : .playOnce
        player.accessibilityLabel = label
        if autoPlay && !reduceMotion {
            if player.animation != nil && !player.isAnimationPlaying { player.play() }
        } else { player.pause(); player.currentProgress = 0 }
    }

    final class Coordinator {
        var player: LottieAnimationView?
        var fallback: UILabel?
        var autoPlay = true
        var reduceMotion = false
    }
}

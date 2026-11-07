import AVKit
import Flutter
import Foundation
import UIKit

final class PushifyPaywallVideoFactory: NSObject, FlutterPlatformViewFactory {
    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        FlutterStandardMessageCodec.sharedInstance()
    }

    func create(withFrame frame: CGRect, viewIdentifier: Int64, arguments args: Any?) -> FlutterPlatformView {
        PushifyPaywallVideoPlatformView(frame: frame, arguments: args as? [String: Any] ?? [:])
    }
}

private final class PushifyPaywallVideoPlatformView: NSObject, FlutterPlatformView {
    private let controller = AVPlayerViewController()
    private let poster = UIImageView()
    private let status = UILabel()
    private let player: AVPlayer
    private let autoPlay: Bool
    private let loops: Bool
    private let muted: Bool
    private let showControls: Bool
    private var observation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?

    init(frame: CGRect, arguments: [String: Any]) {
        let rawURL = arguments["url"] as? String ?? ""
        let url = URL(string: rawURL).flatMap { $0.scheme?.lowercased() == "https" ? $0 : nil }
        player = url.map(AVPlayer.init(url:)) ?? AVPlayer()
        autoPlay = arguments["autoPlay"] as? Bool ?? true
        loops = arguments["loop"] as? Bool ?? true
        muted = arguments["muted"] as? Bool ?? true
        showControls = arguments["showControls"] as? Bool ?? false
        super.init()

        controller.player = player
        player.isMuted = muted
        controller.showsPlaybackControls = showControls
        controller.videoGravity = (arguments["fitMode"] as? String) == "fit" ? .resizeAspect : .resizeAspectFill
        controller.view.frame = frame
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.backgroundColor = .black
        controller.view.accessibilityLabel = arguments["accessibilityLabel"] as? String ?? "Video"

        poster.frame = controller.view.bounds
        poster.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        poster.contentMode = (arguments["fitMode"] as? String) == "fit" ? .scaleAspectFit : .scaleAspectFill
        poster.clipsToBounds = true
        poster.backgroundColor = .black
        if let posterURL = (arguments["posterUrl"] as? String).flatMap(URL.init(string:)), posterURL.scheme?.lowercased() == "https" {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let imageData = try? Data(contentsOf: posterURL), let image = UIImage(data: imageData) else { return }
                DispatchQueue.main.async { self?.poster.image = image }
            }
        }
        controller.view.addSubview(poster)

        status.text = "Video unavailable"
        status.textColor = .white
        status.textAlignment = .center
        status.backgroundColor = .black
        status.frame = controller.view.bounds
        status.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        status.isHidden = url != nil
        controller.view.addSubview(status)

        if let item = player.currentItem, url != nil {
            observation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch item.status {
                    case .readyToPlay:
                        self.status.isHidden = true
                        if self.autoPlay || self.showControls { self.poster.isHidden = true }
                        if self.autoPlay { self.player.play() }
                    case .failed: self.showFailure()
                    default: break
                    }
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in
            guard let self, self.loops else { return }
            self.player.seek(to: .zero) { _ in self.player.play() }
        }
        failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in self?.showFailure() }
    }

    func view() -> UIView { controller.view }

    private func showFailure() {
        player.pause()
        status.text = "Video unavailable"
        status.isHidden = false
        poster.isHidden = poster.image == nil
    }

    deinit {
        player.pause()
        observation?.invalidate()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        player.replaceCurrentItem(with: nil)
    }
}

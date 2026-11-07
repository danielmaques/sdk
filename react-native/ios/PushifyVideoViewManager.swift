import AVKit
import Foundation
import React
import UIKit

@objc(PushifyVideoManager)
final class PushifyVideoManager: RCTViewManager {
    override static func requiresMainQueueSetup() -> Bool { true }
    override func view() -> UIView! { PushifyNativeVideoView() }
}

final class PushifyNativeVideoView: UIView {
    @objc var videoUrl: NSString? { didSet { updatePlayer() } }
    @objc var posterUrl: NSString? { didSet { updatePoster() } }
    @objc var autoPlay = true { didSet { if autoPlay { player?.play() } else { player?.pause() } } }
    @objc var loops = true
    @objc var muted = true { didSet { player?.isMuted = muted } }
    @objc var showControls = false { didSet { controller.showsPlaybackControls = showControls } }
    @objc var fitMode: NSString? { didSet { updateFit() } }
    @objc var accessibilityLabel: NSString? { didSet { controller.view.accessibilityLabel = accessibilityLabel as String? ?? "Video" } }

    private let controller = AVPlayerViewController()
    private let poster = UIImageView()
    private let status = UILabel()
    private var player: AVPlayer?
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var loadedURL: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        controller.view.backgroundColor = .black
        controller.view.clipsToBounds = true
        addSubview(controller.view)
        poster.contentMode = .scaleAspectFill
        poster.clipsToBounds = true
        addSubview(poster)
        status.text = "Loading video…"
        status.textAlignment = .center
        status.textColor = .white
        status.backgroundColor = .black
        addSubview(status)
        isAccessibilityElement = false
        updateFit()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        controller.view.frame = bounds
        poster.frame = bounds
        status.frame = bounds
    }

    private func updatePlayer() {
        guard let raw = videoUrl as String?, let url = URL(string: raw), url.scheme?.lowercased() == "https" else {
            stopPlayer()
            showFailure()
            return
        }
        guard loadedURL != url else { return }
        stopPlayer()
        loadedURL = url
        status.text = "Loading video…"
        status.isHidden = poster.image != nil
        poster.isHidden = false
        let item = AVPlayerItem(url: url)
        let next = AVPlayer(playerItem: item)
        next.isMuted = muted
        player = next
        controller.player = next
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    self.status.isHidden = true
                    if self.autoPlay || self.showControls { self.poster.isHidden = true }
                    if self.autoPlay { self.player?.play() }
                case .failed: self.showFailure()
                default: break
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            guard let self, self.loops, let player = self.player else { return }
            player.seek(to: .zero) { _ in player.play() }
        }
        failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in self?.showFailure() }
        updateFit()
    }

    private func updatePoster() {
        guard let raw = posterUrl as String?, let url = URL(string: raw), url.scheme?.lowercased() == "https" else {
            poster.image = nil
            status.isHidden = false
            return
        }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let image = UIImage(data: data) else { return }
            DispatchQueue.main.async {
                guard self?.posterUrl as String? == url.absoluteString else { return }
                self?.poster.image = image
            }
        }.resume()
    }

    private func updateFit() {
        let fit = fitMode as String? == "fit"
        controller.videoGravity = fit ? .resizeAspect : .resizeAspectFill
        poster.contentMode = fit ? .scaleAspectFit : .scaleAspectFill
    }

    private func showFailure() {
        player?.pause()
        controller.view.isHidden = true
        status.text = "Video unavailable"
        status.isHidden = poster.image != nil
        poster.isHidden = poster.image == nil
    }

    private func stopPlayer() {
        statusObservation?.invalidate()
        statusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        endObserver = nil
        failureObserver = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        controller.player = nil
        loadedURL = nil
        controller.view.isHidden = false
    }

    deinit { stopPlayer() }
}

import AVFoundation
import AppKit
import SwiftUI

struct MediaPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerHostView {
        let view = PlayerHostView(frame: .zero)
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerHostView, context: Context) {
        view.playerLayer.player = player
    }
}

final class PlayerHostView: NSView {
    override func makeBackingLayer() -> CALayer {
        AVPlayerLayer()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = AppTheme.AppKitColor.mediaCanvas.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }
}

import SonovoMediaEngine
import SonovoDocumentSupport
import SonovoFileIO
import SonovoDomainTypes
import SonovoDesignSystem
import AVFoundation
import AppKit
import SwiftUI

package struct MediaPlayerView: NSViewRepresentable {
    package init(player: AVPlayer) { self.player = player }
    package let player: AVPlayer

    package func makeNSView(context: Context) -> PlayerHostView {
        let view = PlayerHostView(frame: .zero)
        view.playerLayer.player = player
        return view
    }

    package func updateNSView(_ view: PlayerHostView, context: Context) {
        view.playerLayer.player = player
    }
}

package final class PlayerHostView: NSView {
    package override func makeBackingLayer() -> CALayer {
        AVPlayerLayer()
    }

    package override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = AppTheme.AppKitColor.mediaCanvas.cgColor
    }

    package required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    package var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }
}

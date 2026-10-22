import AppKit
import SwiftUI

/// Intercepts the window close, runs the workspace flush, and cancels the
/// close when a document still needs a save/discard/cancel decision.
///
/// The flush is a closure rather than a single workspace so both the
/// Markdown and subtitle workspaces can settle before the window closes.
struct WindowCloseGuard: NSViewRepresentable {
    let flush: @MainActor () async -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(flush: flush)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                context.coordinator.install(on: window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                context.coordinator.install(on: window)
            }
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        private let flush: @MainActor () async -> Bool
        private weak var window: NSWindow?
        private weak var original: NSWindowDelegate?
        private var bypass = false

        init(flush: @escaping @MainActor () async -> Bool) {
            self.flush = flush
            super.init()
        }

        func install(on window: NSWindow) {
            guard self.window !== window else { return }
            uninstall()
            self.window = window
            self.original = window.delegate
            window.delegate = self
        }

        func uninstall() {
            guard let window, window.delegate === self else { return }
            window.delegate = original
            self.window = nil
            self.original = nil
        }

        private var flushInFlight = false

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if bypass { return true }
            // A second close click while the first flush is saving would
            // start a parallel save and could invoke the delegate twice.
            guard !flushInFlight else { return false }
            flushInFlight = true

            Task { @MainActor in
                defer { flushInFlight = false }
                guard await flush() else { return }
                // The flush saved our documents; the window's own delegate
                // may still refuse the close.
                guard self.original?.windowShouldClose?(sender) ?? true else {
                    return
                }
                self.bypass = true
                sender.close()
            }
            return false
        }

        override nonisolated func responds(to aSelector: Selector!) -> Bool {
            if super.responds(to: aSelector) { return true }
            return MainActor.assumeIsolated {
                original?.responds(to: aSelector) ?? false
            }
        }

        override nonisolated func forwardingTarget(
            for aSelector: Selector!
        ) -> Any? {
            let forwards = MainActor.assumeIsolated {
                original?.responds(to: aSelector) == true
            }
            if forwards {
                let box = MainActor.assumeIsolated {
                    DelegateBox(original)
                }
                return box.value
            }
            return super.forwardingTarget(for: aSelector)
        }

        /// Carries a weak delegate reference across `assumeIsolated`, whose
        /// generic result must be Sendable.
        private final class DelegateBox: @unchecked Sendable {
            weak var value: NSWindowDelegate?

            init(_ value: NSWindowDelegate?) {
                self.value = value
            }
        }
    }
}

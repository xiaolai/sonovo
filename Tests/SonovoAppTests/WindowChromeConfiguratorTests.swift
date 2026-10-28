import AppKit
import XCTest
@testable import Sonovo

@MainActor
final class WindowChromeConfiguratorTests: XCTestCase {
    /// SwiftUI calls `updateNSView` for every environment change. The chrome
    /// pass walks the whole window tree, so it must run once per window and
    /// toolbar identity, not once per update.
    func testRepeatedSchedulesApplyChromeOnce() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let view = NSView()
        window.contentView = view

        let coordinator = WindowChromeConfigurator.Coordinator()
        var applications = 0
        coordinator.applyChrome = { _ in applications += 1 }

        coordinator.schedule(view)
        coordinator.schedule(view)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(applications, 1)

        // A different window is a new identity and applies again; repeating
        // it is still free.
        let second = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let secondView = NSView()
        second.contentView = secondView
        coordinator.schedule(secondView)
        coordinator.schedule(secondView)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(applications, 2)
    }
}

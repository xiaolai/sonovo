import AppKit
import XCTest
@testable import Sonovo

@MainActor
final class ProjectEditorHostRegistryTests: XCTestCase {
    private var fixture: ProjectUXTestSupport!

    override func setUp() {
        super.setUp()
        fixture = ProjectUXTestSupport()
    }

    override func tearDown() {
        fixture.tearDown()
        fixture = nil
        super.tearDown()
    }

    /// Visibility is observable state, so the container publishes it on the
    /// runloop turn after `sync`/`layout`; the AppKit side (frames and hidden
    /// flags) is immediate.
    private func waitForVisibility(
        _ expected: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<100 {
            if expected() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("visibility was not published after the update")
    }

    func testCreatesOnlyTheActiveHostAndRetainsIt() async throws {
        let first = Project(folderURL: try fixture.makeRoot(name: "one"))
        let second = Project(folderURL: try fixture.makeRoot(name: "two"))
        let container = makeContainer()
        container.frame = NSRect(x: 0, y: 0, width: 400, height: 300)

        container.sync(
            projects: [first, second],
            active: first,
            colorScheme: .light,
            displayScale: 2,
            canvasInset: 8,
            canvasRadius: 12,
            workspaceTheme: .standard
        )

        XCTAssertEqual(container.registry.entries.count, 1)
        let firstEntry = try XCTUnwrap(
            container.registry.entries[ObjectIdentifier(first)]
        )
        XCTAssertTrue(firstEntry.host.superview === container)
        XCTAssertFalse(firstEntry.host.isHidden)
        await waitForVisibility { firstEntry.context.isVisible }
        XCTAssertTrue(firstEntry.context.isVisible)
        XCTAssertEqual(firstEntry.host.frame, container.bounds)

        container.sync(
            projects: [first, second],
            active: second,
            colorScheme: .light,
            displayScale: 2,
            canvasInset: 8,
            canvasRadius: 12,
            workspaceTheme: .standard
        )

        XCTAssertEqual(container.registry.entries.count, 2)
        let secondEntry = try XCTUnwrap(
            container.registry.entries[ObjectIdentifier(second)]
        )
        XCTAssertFalse(secondEntry.host.isHidden)
        await waitForVisibility {
            secondEntry.context.isVisible && !firstEntry.context.isVisible
        }
        XCTAssertTrue(secondEntry.context.isVisible)
        XCTAssertTrue(firstEntry.host.isHidden)
        XCTAssertFalse(firstEntry.context.isVisible)
        // A hidden host keeps its last frame; it is not resized behind the
        // user's back.
        XCTAssertEqual(firstEntry.host.frame, container.bounds)
    }

    func testZeroBoundsHideEveryHostAndKeepFrames() async throws {
        let project = Project(folderURL: try fixture.makeRoot(name: "one"))
        let container = makeContainer()
        container.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        container.sync(
            projects: [project],
            active: project,
            colorScheme: .light,
            displayScale: 2,
            canvasInset: 8,
            canvasRadius: 12,
            workspaceTheme: .standard
        )
        let entry = try XCTUnwrap(
            container.registry.entries[ObjectIdentifier(project)]
        )
        let shownFrame = entry.host.frame

        container.frame = .zero
        container.sync(
            projects: [project],
            active: project,
            colorScheme: .light,
            displayScale: 2,
            canvasInset: 8,
            canvasRadius: 12,
            workspaceTheme: .standard
        )

        XCTAssertTrue(entry.host.isHidden)
        await waitForVisibility { !entry.context.isVisible }
        XCTAssertFalse(entry.context.isVisible)
        XCTAssertEqual(entry.host.frame, shownFrame)
    }

    func testPrunesClosedProjectAndDoesNotReuseHostForReopenedPath() throws {
        let root = try fixture.makeRoot(name: "one")
        let first = Project(folderURL: root)
        let container = makeContainer()
        container.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        container.sync(
            projects: [first],
            active: first,
            colorScheme: .light,
            displayScale: 2,
            canvasInset: 8,
            canvasRadius: 12,
            workspaceTheme: .standard
        )
        let firstHost = try XCTUnwrap(
            container.registry.entries[ObjectIdentifier(first)]?.host
        )

        // A close and reopen of the same folder creates a new Project object
        // with the same path/id. ObjectIdentifier keys must not reuse it.
        let reopened = Project(folderURL: root)
        container.sync(
            projects: [reopened],
            active: reopened,
            colorScheme: .light,
            displayScale: 2,
            canvasInset: 8,
            canvasRadius: 12,
            workspaceTheme: .standard
        )

        XCTAssertEqual(container.registry.entries.count, 1)
        XCTAssertNil(firstHost.superview)
        let reopenedHost = try XCTUnwrap(
            container.registry.entries[ObjectIdentifier(reopened)]?.host
        )
        XCTAssertFalse(firstHost === reopenedHost)
    }

    func testAppearanceAndScaleReachTheContext() throws {
        let project = Project(folderURL: try fixture.makeRoot(name: "one"))
        let container = makeContainer()
        container.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        container.sync(
            projects: [project],
            active: project,
            colorScheme: .light,
            displayScale: 2,
            canvasInset: 8,
            canvasRadius: 12,
            workspaceTheme: .standard
        )
        let context = try XCTUnwrap(
            container.registry.entries[ObjectIdentifier(project)]?.context
        )

        container.sync(
            projects: [project],
            active: project,
            colorScheme: .dark,
            displayScale: 3,
            canvasInset: 4,
            canvasRadius: 6,
            workspaceTheme: .standard
        )

        XCTAssertEqual(context.colorScheme, .dark)
        XCTAssertEqual(context.displayScale, 3)
        XCTAssertEqual(context.canvasInset, 4)
        XCTAssertEqual(context.canvasRadius, 6)
    }

    func testRepeatedSyncPublishesNoUnchangedContext() throws {
        let project = Project(folderURL: try fixture.makeRoot(name: "one"))
        let container = makeContainer()
        container.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        func sync() {
            container.sync(
                projects: [project],
                active: project,
                colorScheme: .light,
                displayScale: 2,
                canvasInset: 8,
                canvasRadius: 12,
                workspaceTheme: .standard
            )
        }
        sync()
        let context = try XCTUnwrap(
            container.registry.entries[ObjectIdentifier(project)]?.context
        )
        let invalidated = HostObservationFlag()
        withObservationTracking {
            _ = context.colorScheme
            _ = context.displayScale
            _ = context.canvasInset
            _ = context.canvasRadius
            _ = context.workspaceTheme
            _ = context.isVisible
            sync()
        } onChange: {
            invalidated.raise()
        }
        XCTAssertFalse(
            invalidated.isRaised,
            "an identical sync republished context state"
        )
    }

    private func makeContainer() -> ProjectEditorHostContainer {
        ProjectEditorHostContainer(
            state: AppState(),
            colorScheme: .light,
            displayScale: 2,
            canvasInset: 8,
            canvasRadius: 12,
            workspaceTheme: .standard,
            hostFactory: { _, _ in NSView() }
        )
    }
}

/// A one-way flag for `withObservationTracking` callbacks, which are
/// `@Sendable`; the write happens synchronously on the main thread.
private final class HostObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    func raise() {
        lock.lock()
        raised = true
        lock.unlock()
    }

    var isRaised: Bool {
        lock.lock()
        defer { lock.unlock() }
        return raised
    }
}

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

    func testCreatesOnlyTheActiveHostAndRetainsIt() throws {
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
            canvasRadius: 12
        )

        XCTAssertEqual(container.registry.entries.count, 1)
        let firstEntry = try XCTUnwrap(
            container.registry.entries[ObjectIdentifier(first)]
        )
        XCTAssertTrue(firstEntry.host.superview === container)
        XCTAssertFalse(firstEntry.host.isHidden)
        XCTAssertTrue(firstEntry.context.isVisible)
        XCTAssertEqual(firstEntry.host.frame, container.bounds)

        container.sync(
            projects: [first, second],
            active: second,
            colorScheme: .light,
            displayScale: 2,
            canvasInset: 8,
            canvasRadius: 12
        )

        XCTAssertEqual(container.registry.entries.count, 2)
        let secondEntry = try XCTUnwrap(
            container.registry.entries[ObjectIdentifier(second)]
        )
        XCTAssertFalse(secondEntry.host.isHidden)
        XCTAssertTrue(secondEntry.context.isVisible)
        XCTAssertTrue(firstEntry.host.isHidden)
        XCTAssertFalse(firstEntry.context.isVisible)
        // A hidden host keeps its last frame; it is not resized behind the
        // user's back.
        XCTAssertEqual(firstEntry.host.frame, container.bounds)
    }

    func testZeroBoundsHideEveryHostAndKeepFrames() throws {
        let project = Project(folderURL: try fixture.makeRoot(name: "one"))
        let container = makeContainer()
        container.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        container.sync(
            projects: [project],
            active: project,
            colorScheme: .light,
            displayScale: 2,
            canvasInset: 8,
            canvasRadius: 12
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
            canvasRadius: 12
        )

        XCTAssertTrue(entry.host.isHidden)
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
            canvasRadius: 12
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
            canvasRadius: 12
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
            canvasRadius: 12
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
            canvasRadius: 6
        )

        XCTAssertEqual(context.colorScheme, .dark)
        XCTAssertEqual(context.displayScale, 3)
        XCTAssertEqual(context.canvasInset, 4)
        XCTAssertEqual(context.canvasRadius, 6)
    }

    private func makeContainer() -> ProjectEditorHostContainer {
        ProjectEditorHostContainer(
            state: AppState(),
            colorScheme: .light,
            displayScale: 2,
            canvasInset: 8,
            canvasRadius: 12,
            hostFactory: { _, _ in NSView() }
        )
    }
}

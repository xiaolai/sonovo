import XCTest
@testable import Sonovo

@MainActor
final class ProjectSwitcherModelTests: XCTestCase {
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

    func testEntriesFollowOpenOrderAndEndWithDemo() throws {
        let workspace = fixture.makeWorkspace()
        var model = ProjectSwitcherModel(workspace: workspace)

        XCTAssertEqual(
            model.entries.map(\.id),
            [workspace.demoProject.id]
        )

        let first = try XCTUnwrap(
            workspace.openProject(
                at: try fixture.makeRoot(name: "one")
            )
        )
        model = ProjectSwitcherModel(workspace: workspace)

        XCTAssertEqual(
            model.entries.map(\.id),
            [first.id, workspace.demoProject.id]
        )
    }

    func testTwoProjectsKeepStableOrder() throws {
        let workspace = fixture.makeWorkspace()
        let first = try XCTUnwrap(
            workspace.openProject(
                at: try fixture.makeRoot(name: "one")
            )
        )
        let second = try XCTUnwrap(
            workspace.openProject(
                at: try fixture.makeRoot(name: "two")
            )
        )

        let model = ProjectSwitcherModel(workspace: workspace)

        XCTAssertEqual(
            model.entries.map(\.id),
            [first.id, second.id, workspace.demoProject.id]
        )
        XCTAssertEqual(
            model.entries.map(\.shortcutIndex),
            [1, 2, 3]
        )
        XCTAssertEqual(model.entries[0].name, "one")
        XCTAssertEqual(model.entries[1].name, "two")
        XCTAssertEqual(model.entries[2].name, "Sample")
        XCTAssertFalse(model.entries[2].canClose)
        XCTAssertTrue(model.entries[0].canClose)
        XCTAssertFalse(model.entries[0].isActive)
        XCTAssertTrue(model.entries[1].isActive)
    }

    func testActivationDoesNotReorderEntries() throws {
        let workspace = fixture.makeWorkspace()
        let first = try XCTUnwrap(
            workspace.openProject(
                at: try fixture.makeRoot(name: "one")
            )
        )
        let second = try XCTUnwrap(
            workspace.openProject(
                at: try fixture.makeRoot(name: "two")
            )
        )
        let before = ProjectSwitcherModel(workspace: workspace)
            .entries.map(\.id)

        workspace.activate(first)

        let after = ProjectSwitcherModel(workspace: workspace)
        XCTAssertEqual(after.entries.map(\.id), before)
        XCTAssertTrue(after.entries[0].isActive)
        XCTAssertFalse(after.entries[1].isActive)
        XCTAssertEqual(
            after.entries[1].id,
            second.id
        )
    }

    func testShortcutIndexCoversOnlyTheFirstNine() {
        for position in 0..<9 {
            XCTAssertEqual(
                ProjectSwitcherModel.shortcutIndex(for: position),
                position + 1
            )
        }
        XCTAssertNil(ProjectSwitcherModel.shortcutIndex(for: 9))
        XCTAssertNil(ProjectSwitcherModel.shortcutIndex(for: 12))
        XCTAssertNil(ProjectSwitcherModel.shortcutIndex(for: -1))
    }

    func testDuplicateNamesKeepDistinctIdentityAndDetail() throws {
        let workspace = fixture.makeWorkspace()
        let first = try XCTUnwrap(
            workspace.openProject(
                at: try fixture.makeRoot(name: "cuts")
            )
        )
        let second = try XCTUnwrap(
            workspace.openProject(
                at: try fixture.makeRoot(name: "cuts")
            )
        )

        let entries = ProjectSwitcherModel(workspace: workspace).entries

        XCTAssertEqual(entries[0].name, "cuts")
        XCTAssertEqual(entries[1].name, "cuts")
        XCTAssertNotEqual(entries[0].id, entries[1].id)
        XCTAssertNotEqual(entries[0].detail, entries[1].detail)
        XCTAssertEqual(entries[0].id, first.id)
        XCTAssertEqual(entries[1].id, second.id)
    }

    func testAttentionTravelsIntoTheEntry() throws {
        let workspace = fixture.makeWorkspace()
        let project = try XCTUnwrap(
            workspace.openProject(
                at: try fixture.makeRoot(name: "one")
            )
        )
        project.hasActivity = true

        let entry = try XCTUnwrap(
            ProjectSwitcherModel(workspace: workspace)
                .entries
                .first { $0.id == project.id }
        )

        XCTAssertTrue(
            entry.attention.statuses.contains(.backgroundChanges)
        )
    }
}

import Foundation
import SonovoCore
import XCTest
@testable import Sonovo

@MainActor
final class CodeDocumentTests: XCTestCase {
    private var support: CodeTestSupport!

    override func setUp() {
        super.setUp()
        support = CodeTestSupport()
    }

    override func tearDown() {
        support.tearDown()
        support = nil
        super.tearDown()
    }

    private func makeDocument(
        _ data: Data,
        name: String = "file.swift"
    ) async throws -> (CodeDocument, URL) {
        let root = try support.makeRoot(files: [name: data])
        let url = root.appendingPathComponent(name)
        let document = CodeDocument(url: url)
        await document.load()
        return (document, url)
    }

    // MARK: - External changes

    func testCleanVisibleChangeAdoptsAndUpdatesBothBaselines() async throws {
        let (document, url) = try await makeDocument(
            CodeTestData.utf8("let a = 1\n")
        )
        try support.write(
            CodeTestData.utf8("let a = 2\n"),
            to: url
        )
        let change = await document.checkExternalChange(projectVisible: true)
        XCTAssertEqual(change, .adopted)
        XCTAssertEqual(document.source, "let a = 2\n")
        XCTAssertEqual(
            document.lastAcknowledged?.bytes,
            CodeTestData.utf8("let a = 2\n")
        )
        XCTAssertEqual(
            document.lastSaved?.bytes,
            CodeTestData.utf8("let a = 2\n")
        )
        XCTAssertFalse(document.pendingReview)
    }

    func testHiddenChangeAdvancesOnlyTheDisk() async throws {
        let initial = CodeTestData.utf8("let a = 1\n")
        let (document, url) = try await makeDocument(initial)
        try support.write(
            CodeTestData.utf8("let a = 2\n"),
            to: url
        )
        let change = await document.checkExternalChange(
            projectVisible: false
        )
        XCTAssertEqual(change, .pendingReview)
        XCTAssertEqual(document.source, "let a = 1\n")
        XCTAssertEqual(
            document.diskSnapshot?.bytes,
            CodeTestData.utf8("let a = 2\n")
        )
        XCTAssertEqual(document.lastAcknowledged?.bytes, initial)
        XCTAssertTrue(document.pendingReview)
    }

    func testAtoBtoCHiddenShowsAToC() async throws {
        let a = CodeTestData.utf8("let value = 1\n")
        let (document, url) = try await makeDocument(a)
        try support.write(
            CodeTestData.utf8("let value = 2\n"),
            to: url
        )
        _ = await document.checkExternalChange(projectVisible: false)
        try support.write(
            CodeTestData.utf8("let value = 3\n"),
            to: url
        )
        _ = await document.checkExternalChange(projectVisible: false)

        document.captureReviewDiff()
        let pair = try XCTUnwrap(document.reviewedDiff)
        XCTAssertEqual(pair.left.bytes, a)
        XCTAssertEqual(
            pair.right.bytes,
            CodeTestData.utf8("let value = 3\n")
        )
        // Viewing the diff acknowledges C.
        XCTAssertEqual(document.lastAcknowledged?.bytes, pair.right.bytes)
        XCTAssertFalse(document.pendingReview)
    }

    func testDirtyBOMOnlyChangeIsAConflict() async throws {
        let (document, url) = try await makeDocument(
            CodeTestData.utf8("let a = 1\n")
        )
        try document.replaceSource("let a = 2\n")
        try support.write(
            CodeTestData.bom("let a = 1\n"),
            to: url
        )
        let change = await document.checkExternalChange(
            projectVisible: true
        )
        guard case .conflict(let conflict) = change else {
            return XCTFail("expected a conflict, got \(change)")
        }
        XCTAssertEqual(
            conflict.diskSnapshot.bytes,
            CodeTestData.bom("let a = 1\n")
        )
        XCTAssertEqual(document.source, "let a = 2\n")
    }

    func testReloadAndKeepMineResolveAConflict() async throws {
        let external = CodeTestData.utf8("let a = 2\n")
        let (document, url) = try await makeDocument(
            CodeTestData.utf8("let a = 1\n")
        )
        try document.replaceSource("let a = 3\n")
        try support.write(external, to: url)
        _ = await document.checkExternalChange(projectVisible: true)

        await document.resolveConflict(.reload)
        XCTAssertNil(document.conflict)
        XCTAssertEqual(document.source, "let a = 2\n")
        XCTAssertFalse(document.isDirty)
    }

    func testKeepMineKeepsTheBufferAndTheConflictBaseline() async throws {
        let external = CodeTestData.utf8("let a = 2\n")
        let (document, url) = try await makeDocument(
            CodeTestData.utf8("let a = 1\n")
        )
        try document.replaceSource("let a = 3\n")
        try support.write(external, to: url)
        _ = await document.checkExternalChange(projectVisible: true)

        await document.resolveConflict(.keepLocal)
        XCTAssertNil(document.conflict)
        XCTAssertEqual(document.source, "let a = 3\n")
        XCTAssertTrue(document.isDirty)
        XCTAssertEqual(document.diskSnapshot?.bytes, external)
    }

    func testAFileThatGrowsPastTheCapConflicts() async throws {
        let (document, url) = try await makeDocument(
            CodeTestData.utf8("let a = 1\n")
        )
        try document.replaceSource("let a = 2\n")
        try support.write(
            Data(repeating: 0x61, count: CodeLimits.maximumReadBytes + 1),
            to: url
        )
        let change = await document.checkExternalChange(
            projectVisible: true
        )
        guard case .conflict(let conflict) = change else {
            return XCTFail("expected a conflict, got \(change)")
        }
        XCTAssertTrue(conflict.detail.contains("8 MB"))
    }

    // MARK: - Save races

    func testADiskChangeBetweenOpenAndSaveIsADetectedConflict() async throws {
        let (document, url) = try await makeDocument(
            CodeTestData.utf8("let a = 1\n")
        )
        try document.replaceSource("let a = 2\n")
        let external = CodeTestData.utf8("let a = 9\n")
        try support.write(external, to: url)

        do {
            try await document.save()
            XCTFail("save must detect the external change")
        } catch let error as SaveError {
            guard case .diskChanged = error else {
                return XCTFail("expected diskChanged, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: url), external)
        XCTAssertTrue(document.isDirty)
        XCTAssertNotNil(document.conflict)
    }

    func testEditDuringAnInFlightSaveStaysDirty() async throws {
        let (document, url) = try await makeDocument(
            CodeTestData.utf8("let a = 1\n")
        )
        try document.replaceSource("let a = 2\n")
        let entered = expectation(description: "before rename")
        let gate = DispatchSemaphore(value: 0)
        let hooks = SaveHooks(beforeRename: { _ in
            entered.fulfill()
            gate.wait()
        })
        let saveTask = Task {
            try await document.save(hooks: hooks)
        }
        await fulfillment(of: [entered], timeout: 5)
        try document.replaceSource("let a = 3\n")
        gate.signal()
        _ = try await saveTask.value

        XCTAssertEqual(
            try Data(contentsOf: url),
            CodeTestData.utf8("let a = 2\n")
        )
        XCTAssertTrue(document.isDirty)
        XCTAssertEqual(document.source, "let a = 3\n")
    }

    func testASecondSaveQueuesBehindTheFirst() async throws {
        let (document, _) = try await makeDocument(
            CodeTestData.utf8("let a = 1\n")
        )
        try document.replaceSource("let a = 2\n")
        let entered = expectation(description: "before rename")
        let gate = DispatchSemaphore(value: 0)
        let hooks = SaveHooks(beforeRename: { _ in
            entered.fulfill()
            gate.wait()
        })
        let first = Task { try await document.save(hooks: hooks) }
        await fulfillment(of: [entered], timeout: 5)
        let second = Task { try await document.save() }
        gate.signal()
        do {
            _ = try await first.value
        } catch {
            XCTFail("first save failed: \(error)")
        }
        do {
            _ = try await second.value
        } catch {
            XCTFail("second save failed: \(error)")
        }
        XCTAssertFalse(document.isDirty)
    }

    func testClosedDuringSaveDoesNotResurrectTheDocument() async throws {
        let (document, _) = try await makeDocument(
            CodeTestData.utf8("let a = 1\n")
        )
        try document.replaceSource("let a = 2\n")
        let entered = expectation(description: "before rename")
        let gate = DispatchSemaphore(value: 0)
        let hooks = SaveHooks(beforeRename: { _ in
            entered.fulfill()
            gate.wait()
        })
        let task = Task { try await document.save(hooks: hooks) }
        await fulfillment(of: [entered], timeout: 5)
        document.markClosed()
        gate.signal()
        do {
            _ = try await task.value
            XCTFail("a closed document must reject the completion")
        } catch {
            XCTAssertEqual(error as? CodeDocumentError, .closed)
        }
        XCTAssertTrue(document.isClosed)
    }

    func testSaveQueuedBehindSaveAsUsesTheNewIdentity() async throws {
        let (document, _) = try await makeDocument(
            CodeTestData.utf8("let a = 1\n")
        )
        try document.replaceSource("let a = 2\n")
        let root = try support.makeRoot()
        let destination = root.appendingPathComponent("moved.swift")
        let entered = expectation(description: "before rename")
        let gate = DispatchSemaphore(value: 0)
        let hooks = SaveHooks(beforeRename: { _ in
            entered.fulfill()
            gate.wait()
        })
        let saveAsTask = Task {
            try await document.saveAs(to: destination, hooks: hooks)
        }
        await fulfillment(of: [entered], timeout: 5)
        let saveTask = Task { try await document.save() }
        gate.signal()
        _ = try await saveAsTask.value
        _ = try await saveTask.value
        XCTAssertEqual(document.fileURL, destination)
        XCTAssertEqual(
            try Data(contentsOf: destination),
            CodeTestData.utf8("let a = 2\n")
        )
        XCTAssertFalse(document.isDirty)
    }

    func testDiscardDuringSaveAsDoesNotResurrectTheDocument() async throws {
        let (document, original) = try await makeDocument(
            CodeTestData.utf8("let a = 1\n")
        )
        try document.replaceSource("let a = 2\n")
        let root = try support.makeRoot()
        let destination = root.appendingPathComponent("discarded.swift")
        let entered = expectation(description: "before rename")
        let gate = DispatchSemaphore(value: 0)
        let hooks = SaveHooks(beforeRename: { _ in
            entered.fulfill()
            gate.wait()
        })
        let task = Task {
            try await document.saveAs(to: destination, hooks: hooks)
        }
        await fulfillment(of: [entered], timeout: 5)
        document.markClosed()
        gate.signal()
        do {
            _ = try await task.value
            XCTFail("a closed document must reject the completion")
        } catch {
            XCTAssertEqual(error as? CodeDocumentError, .closed)
        }
        XCTAssertTrue(document.isClosed)
        XCTAssertEqual(document.fileURL, original)
    }

    func testEditingAfterAHiddenChangeConflictsInsteadOfOverwriting() async throws {
        let a = CodeTestData.utf8("let a = 1\n")
        let c = CodeTestData.utf8("let a = 3\n")
        let (document, url) = try await makeDocument(a)
        try support.write(c, to: url)
        _ = await document.checkExternalChange(projectVisible: false)
        XCTAssertTrue(document.pendingReview)

        // The buffer is still A, so editing it and saving must compare
        // against A, not against the newer C on disk.
        try document.replaceSource("let a = 2\n")
        do {
            try await document.save()
            XCTFail("the unreviewed disk change must not be overwritten")
        } catch let error as SaveError {
            guard case .diskChanged = error else {
                return XCTFail("expected diskChanged, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: url), c)
        XCTAssertNotNil(document.conflict)
        XCTAssertTrue(document.isDirty)
    }

    func testEditingAfterReviewingAHiddenChangeStillUsesTheBufferBaseline() async throws {
        let a = CodeTestData.utf8("let a = 1\n")
        let c = CodeTestData.utf8("let a = 3\n")
        let (document, url) = try await makeDocument(a)
        try support.write(c, to: url)
        _ = await document.checkExternalChange(projectVisible: false)
        XCTAssertTrue(document.pendingReview)

        // Reviewing A→C acknowledges C, but the buffer is still A. Editing
        // it must compare against A, not against the version the user merely
        // looked at.
        document.captureReviewDiff()
        XCTAssertEqual(document.lastAcknowledged?.bytes, c)
        try document.replaceSource("let a = 2\n")
        do {
            try await document.save()
            XCTFail("the reviewed-but-not-loaded disk version must not be overwritten")
        } catch let error as SaveError {
            guard case .diskChanged = error else {
                return XCTFail("expected diskChanged, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: url), c)
        XCTAssertNotNil(document.conflict)
    }

    func testKeepMineOnABinaryDiskMarksTheBufferDirtyAndSaves() async throws {
        let original = CodeTestData.utf8("let a = 1\n")
        let (document, url) = try await makeDocument(original)
        XCTAssertFalse(document.isDirty)
        try support.write(Data([0x00, 0x01, 0x02]), to: url)

        let change = await document.checkExternalChange(projectVisible: true)
        guard case .conflict(let conflict) = change else {
            return XCTFail("expected a conflict, got \(change)")
        }
        XCTAssertNil(conflict.diskText)
        XCTAssertTrue(
            conflict.diskIsExact,
            "binary bytes within the cap are captured exactly"
        )

        await document.resolveConflict(.keepLocal)
        XCTAssertTrue(
            document.isDirty,
            "Keep Mine must make the next Save actually write"
        )
        _ = try await document.save()
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertFalse(document.isDirty)
    }

    func testCapturingAReviewDiffAboveTheCapDoesNotAcknowledge() async throws {
        let a = Data(repeating: 0x61, count: CodeLimits.editableBytes)
        let (document, url) = try await makeDocument(a)
        let c = Data(repeating: 0x62, count: CodeLimits.diffBytesPerSide + 512)
        try support.write(c, to: url)
        let change = await document.checkExternalChange(
            projectVisible: false
        )
        XCTAssertEqual(change, .pendingReview)

        document.captureReviewDiff()
        XCTAssertNil(
            document.reviewedDiff,
            "an over-cap diff must not be captured"
        )
        XCTAssertTrue(
            document.pendingReview,
            "the review stays available when the diff cannot be shown"
        )
        XCTAssertEqual(
            document.lastAcknowledged?.bytes,
            a,
            "a refused capture must not acknowledge C"
        )
    }

    func testKeepMineOnAnOversizedDiskFailsLoudly() async throws {
        let original = CodeTestData.utf8("let a = 1\n")
        let (document, url) = try await makeDocument(original)
        let oversized = Data(
            repeating: 0x61,
            count: CodeLimits.maximumReadBytes + 1
        )
        try support.write(oversized, to: url)
        let change = await document.checkExternalChange(projectVisible: true)
        guard case .conflict(let conflict) = change else {
            return XCTFail("expected a conflict, got \(change)")
        }
        XCTAssertFalse(
            conflict.diskIsExact,
            "an over-cap file cannot be captured as a save precondition"
        )

        await document.resolveConflict(.keepLocal)
        XCTAssertTrue(
            document.isDirty,
            "Keep Mine must not leave a clean buffer over an unwritten disk"
        )
        do {
            _ = try await document.save()
            XCTFail("replacing an over-cap file must fail loudly")
        } catch let error as CodeDocumentError {
            guard case .readFailed(let message) = error else {
                return XCTFail("expected readFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("Save As"))
        }
        XCTAssertEqual(try Data(contentsOf: url), oversized)
        XCTAssertTrue(document.isDirty)
    }

    func testReloadIsUnavailableWhenTheConflictHasNoText() async throws {
        let (document, url) = try await makeDocument(
            CodeTestData.utf8("let a = 1\n")
        )
        try support.write(Data([0x00, 0x01, 0x02]), to: url)
        _ = await document.checkExternalChange(projectVisible: true)
        await document.resolveConflict(.reload)
        XCTAssertNotNil(
            document.conflict,
            "a conflict without decodable text stays open"
        )
        XCTAssertEqual(document.source, "let a = 1\n")
    }

    func testANormalizationOnlyReplacementIsAnEdit() async throws {
        let composed = "caf\u{E9}\n"
        let decomposed = "cafe\u{301}\n"
        XCTAssertEqual(
            composed,
            decomposed,
            "Swift considers these canonically equal"
        )
        let (document, url) = try await makeDocument(
            CodeTestData.utf8(composed)
        )
        try document.replaceSource(decomposed)
        XCTAssertTrue(
            document.isDirty,
            "a byte change is an edit even when the strings compare equal"
        )
        _ = try await document.save()
        XCTAssertEqual(try Data(contentsOf: url), CodeTestData.utf8(decomposed))
    }

    func testReloadDuringSaveAsResolvesAfterTheWrite() async throws {
        let (document, url) = try await makeDocument(
            CodeTestData.utf8("let a = 1\n")
        )
        try document.replaceSource("let a = 2\n")
        // Establish a conflict first, then Save As while it is still open.
        try support.write(CodeTestData.utf8("let a = 9\n"), to: url)
        do {
            try await document.save()
        } catch {
            // diskChanged is expected and sets the conflict.
        }
        XCTAssertNotNil(document.conflict)

        let root = try support.makeRoot()
        let destination = root.appendingPathComponent("moved.swift")
        let entered = expectation(description: "before rename")
        let gate = DispatchSemaphore(value: 0)
        let hooks = SaveHooks(beforeRename: { _ in
            entered.fulfill()
            gate.wait()
        })
        let saveTask = Task {
            try await document.saveAs(to: destination, hooks: hooks)
        }
        await fulfillment(of: [entered], timeout: 5)

        // The resolution must queue behind the write. The hook proves it
        // reached the slot wait before the write is released.
        let waiting = expectation(description: "resolution waits for the slot")
        document.conflictResolutionWaitHook = { waiting.fulfill() }
        document.queueConflictResolution(.reload)
        await fulfillment(of: [waiting], timeout: 5)
        XCTAssertTrue(document.hasQueuedConflictResolution)
        gate.signal()
        _ = try await saveTask.value
        await document.waitForQueuedConflictResolution()

        XCTAssertEqual(document.source, "let a = 2\n")
        XCTAssertFalse(document.isDirty)
        XCTAssertNil(document.conflict)
        XCTAssertEqual(
            try Data(contentsOf: destination),
            CodeTestData.utf8("let a = 2\n")
        )
    }

    func testTwoQueuedResolutionsDrainTogether() async throws {
        let (document, url) = try await makeDocument(
            CodeTestData.utf8("let a = 1\n")
        )
        try document.replaceSource("let a = 2\n")
        try support.write(CodeTestData.utf8("let a = 9\n"), to: url)
        do {
            try await document.save()
        } catch {
            // The conflict this establishes gives both queued decisions
            // something to resolve.
        }
        XCTAssertNotNil(document.conflict)

        let root = try support.makeRoot()
        let destination = root.appendingPathComponent("moved.swift")
        let entered = expectation(description: "before rename")
        let gate = DispatchSemaphore(value: 0)
        let hooks = SaveHooks(beforeRename: { _ in
            entered.fulfill()
            gate.wait()
        })
        let saveTask = Task {
            try await document.saveAs(to: destination, hooks: hooks)
        }
        await fulfillment(of: [entered], timeout: 5)

        var waits = 0
        let firstWait = expectation(description: "first decision waits")
        let secondWait = expectation(description: "second decision waits")
        secondWait.isInverted = true
        document.conflictResolutionWaitHook = {
            waits += 1
            if waits == 1 {
                firstWait.fulfill()
            } else {
                secondWait.fulfill()
            }
        }
        document.queueConflictResolution(.reload)
        // The first decision is suspended on the slot. The second must not
        // even reach its entry hook: it is chained behind the first.
        await fulfillment(of: [firstWait], timeout: 5)
        document.queueConflictResolution(.keepLocal)
        await fulfillment(of: [secondWait], timeout: 1)
        XCTAssertEqual(
            waits,
            1,
            "a successor cannot start while its predecessor is suspended"
        )

        gate.signal()
        _ = try await saveTask.value
        await document.waitForQueuedConflictResolution()
        XCTAssertEqual(
            waits,
            2,
            "the drain waits for the whole chain, not just its tail"
        )
    }

    func testADeletedFileIsReportedAsDeleted() async throws {
        let (document, url) = try await makeDocument(
            CodeTestData.utf8("let a = 1\n")
        )
        try FileManager.default.removeItem(at: url)
        let change = await document.checkExternalChange(
            projectVisible: true
        )
        XCTAssertEqual(change, .deleted)
        XCTAssertTrue(document.isMissingOnDisk)
    }

    func testARepeatedWatcherEventKeepsThePendingReview() async throws {
        let (document, url) = try await makeDocument(
            CodeTestData.utf8("let a = 1\n")
        )
        try support.write(CodeTestData.utf8("let a = 2\n"), to: url)
        _ = await document.checkExternalChange(projectVisible: false)
        XCTAssertTrue(document.pendingReview)
        let again = await document.checkExternalChange(
            projectVisible: false
        )
        XCTAssertEqual(again, .none)
        XCTAssertTrue(
            document.pendingReview,
            "an unchanged disk must not dismiss the awaiting review"
        )
    }

    func testReloadToALoneCRFileBecomesReadOnly() async throws {
        let (document, url) = try await makeDocument(
            CodeTestData.utf8("let a = 1\n")
        )
        try support.write(CodeTestData.utf8("let a = 1\rlet b = 2"), to: url)
        let change = await document.checkExternalChange(
            projectVisible: true
        )
        XCTAssertEqual(change, .adopted)
        XCTAssertEqual(document.readOnlyReason, .loneCarriageReturn)
        XCTAssertThrowsError(try document.replaceSource("changed"))
    }

    func testSaveAsFromAPermissionReadOnlyDocumentClearsThePolicy() async throws {
        let (document, url) = try await makeDocument(
            CodeTestData.utf8("let a = 1\n")
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444],
            ofItemAtPath: url.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: url.path
            )
        }
        let reloaded = CodeDocument(url: url)
        await reloaded.load()
        XCTAssertEqual(reloaded.readOnlyReason, .permissions)

        let root = try support.makeRoot()
        let destination = root.appendingPathComponent("writable.swift")
        try await reloaded.saveAs(to: destination)
        XCTAssertNil(reloaded.readOnlyReason)
        XCTAssertEqual(reloaded.fileURL, destination)
        XCTAssertEqual(
            try Data(contentsOf: destination),
            CodeTestData.utf8("let a = 1\n")
        )
    }

    func testSecondSaveAsQueuedBehindTheFirstUsesTheNewIdentity() async throws {
        let (document, _) = try await makeDocument(
            CodeTestData.utf8("let a = 1\n")
        )
        try document.replaceSource("let a = 2\n")
        let root = try support.makeRoot()
        let firstDestination = root.appendingPathComponent("first.swift")
        let secondDestination = root.appendingPathComponent("second.swift")
        let entered = expectation(description: "before rename")
        let gate = DispatchSemaphore(value: 0)
        let hooks = SaveHooks(beforeRename: { _ in
            entered.fulfill()
            gate.wait()
        })
        let first = Task {
            try await document.saveAs(to: firstDestination, hooks: hooks)
        }
        await fulfillment(of: [entered], timeout: 5)
        let second = Task {
            try await document.saveAs(to: secondDestination)
        }
        gate.signal()
        _ = try await first.value
        _ = try await second.value

        XCTAssertEqual(document.fileURL, secondDestination)
        XCTAssertEqual(
            try Data(contentsOf: firstDestination),
            CodeTestData.utf8("let a = 2\n")
        )
        XCTAssertEqual(
            try Data(contentsOf: secondDestination),
            CodeTestData.utf8("let a = 2\n")
        )
    }

    // MARK: - Revert

    func testRevertRestoresExactDiskBytes() async throws {
        let disk = CodeTestData.bom("let a = 2\n")
        let (document, url) = try await makeDocument(
            CodeTestData.utf8("let a = 1\n")
        )
        try document.replaceSource("let a = 3\n")
        try support.write(disk, to: url)
        _ = await document.checkExternalChange(projectVisible: true)
        // Keep mine, then revert: the buffer is discarded for the disk.
        await document.resolveConflict(.keepLocal)
        try await document.revertToDisk()
        XCTAssertEqual(document.source, "let a = 2\n")
        XCTAssertTrue(document.hasBOM)
        XCTAssertFalse(document.isDirty)
        XCTAssertEqual(document.diskSnapshot?.bytes, disk)
    }

    func testRevertIsRefusedWhileAConflictIsUnresolved() async throws {
        let (document, url) = try await makeDocument(
            CodeTestData.utf8("let a = 1\n")
        )
        try document.replaceSource("let a = 2\n")
        try support.write(CodeTestData.utf8("let a = 9\n"), to: url)
        _ = await document.checkExternalChange(projectVisible: true)
        do {
            try await document.revertToDisk()
            XCTFail("revert must wait for the conflict decision")
        } catch {
            XCTAssertNotNil(document.conflict)
        }
    }

    // MARK: - Save As

    func testSaveAsSamePathUsesTheDocumentBaseline() async throws {
        let (document, url) = try await makeDocument(
            CodeTestData.utf8("let a = 1\n")
        )
        try document.replaceSource("let a = 2\n")
        // The destination changes after the buffer was based on it.
        let external = CodeTestData.utf8("let a = 9\n")
        try support.write(external, to: url)

        do {
            try await document.saveAs(to: url)
            XCTFail("the original baseline must protect the file")
        } catch let error as SaveError {
            guard case .diskChanged = error else {
                return XCTFail("expected diskChanged, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: url), external)
    }

    func testSaveAsNewPathRequiresAnOverwriteConfirmation() async throws {
        let (document, _) = try await makeDocument(
            CodeTestData.utf8("let a = 1\n")
        )
        try document.replaceSource("let a = 2\n")
        let root = try support.makeRoot()
        let destination = root.appendingPathComponent("copy.swift")
        try support.write(
            CodeTestData.utf8("existing\n"),
            to: destination
        )

        do {
            try await document.saveAs(to: destination)
            XCTFail("an existing destination needs confirmation")
        } catch let error as CodeDocumentError {
            guard case .overwriteConfirmationRequired(
                let url,
                let expected
            ) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(url, destination)
            XCTAssertEqual(expected.bytes, CodeTestData.utf8("existing\n"))
        }

        let expected = try XCTUnwrap(
            DiskTestSnapshot.snapshot(at: destination)
        )
        try await document.saveAs(
            to: destination,
            overwrite: CodeOverwriteConfirmation(
                url: destination,
                expected: expected
            )
        )
        XCTAssertEqual(document.fileURL, destination)
        XCTAssertEqual(
            try Data(contentsOf: destination),
            CodeTestData.utf8("let a = 2\n")
        )
    }

    func testSaveAsAbsentPathCreatesAndMovesIdentity() async throws {
        let (document, _) = try await makeDocument(
            CodeTestData.utf8("let a = 1\n")
        )
        try document.replaceSource("let a = 2\n")
        let root = try support.makeRoot()
        let destination = root.appendingPathComponent("new.swift")
        try await document.saveAs(to: destination)
        XCTAssertEqual(document.fileURL, destination)
        XCTAssertEqual(
            try Data(contentsOf: destination),
            CodeTestData.utf8("let a = 2\n")
        )
        XCTAssertFalse(document.isDirty)
    }

    func testSaveAsRejectsADestinationChangedAfterConfirmation() async throws {
        let (document, _) = try await makeDocument(
            CodeTestData.utf8("let a = 1\n")
        )
        try document.replaceSource("let a = 2\n")
        let root = try support.makeRoot()
        let destination = root.appendingPathComponent("copy.swift")
        try support.write(
            CodeTestData.utf8("first\n"),
            to: destination
        )
        let captured = try XCTUnwrap(
            DiskTestSnapshot.snapshot(at: destination)
        )
        try support.write(
            CodeTestData.utf8("second\n"),
            to: destination
        )
        do {
            try await document.saveAs(
                to: destination,
                overwrite: CodeOverwriteConfirmation(
                    url: destination,
                    expected: captured
                )
            )
            XCTFail("a stale confirmation must not overwrite")
        } catch let error as CodeDocumentError {
            XCTAssertEqual(error, .destinationChanged)
        }
    }

    func testReviewedDiffDoesNotMoveWhenTheDiskMovesAgain() async throws {
        let (document, url) = try await makeDocument(
            CodeTestData.utf8("let value = 1\n")
        )
        try support.write(
            CodeTestData.utf8("let value = 2\n"),
            to: url
        )
        _ = await document.checkExternalChange(projectVisible: false)
        document.captureReviewDiff()
        let captured = try XCTUnwrap(document.reviewedDiff)

        try support.write(
            CodeTestData.utf8("let value = 3\n"),
            to: url
        )
        _ = await document.checkExternalChange(projectVisible: false)
        XCTAssertEqual(
            document.reviewedDiff,
            captured,
            "a review pair is stable while it is on screen"
        )

        document.captureReviewDiff()
        let next = try XCTUnwrap(document.reviewedDiff)
        XCTAssertEqual(
            next.left.bytes,
            CodeTestData.utf8("let value = 2\n")
        )
        XCTAssertEqual(
            next.right.bytes,
            CodeTestData.utf8("let value = 3\n")
        )
    }

    func testDirtyBufferDiffIsSavedToBufferAndDoesNotAcknowledge() async throws {
        let (document, _) = try await makeDocument(
            CodeTestData.utf8("let a = 1\n")
        )
        let acknowledged = document.lastAcknowledged
        try document.replaceSource("let a = 2\n")
        document.captureReviewDiff()
        XCTAssertEqual(
            document.lastAcknowledged,
            acknowledged,
            "a dirty buffer's diff must not advance the disk baseline"
        )
        guard case .available(let pair) = document.availableDiff else {
            return XCTFail("expected an available diff")
        }
        XCTAssertEqual(pair.leftLabel, "Saved")
        XCTAssertEqual(pair.rightLabel, "Buffer")
        XCTAssertEqual(pair.left.bytes, CodeTestData.utf8("let a = 1\n"))
        XCTAssertEqual(pair.right.bytes, CodeTestData.utf8("let a = 2\n"))
    }

    func testUnreadablePathIsRefusedWithTheError() async throws {
        let root = try support.makeRoot(
            files: ["file.swift": CodeTestData.utf8("let a = 1\n")]
        )
        let directory = root.appendingPathComponent("folder.swift")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let document = CodeDocument(url: directory)
        await document.load()
        guard case .unreadable(let detail) = document.refusal else {
            return XCTFail("a directory must be refused, got \(String(describing: document.refusal))")
        }
        XCTAssertTrue(detail.contains("regular file"))
    }

    // MARK: - References

    func testReferenceUsesOneLinePathLineColumn() async throws {
        let root = try support.makeRoot(
            files: ["file.swift": CodeTestData.utf8("a\n  b c\n")]
        )
        let url = root.appendingPathComponent("file.swift")
        let document = CodeDocument(url: url)
        await document.load()
        document.selection = 3..<3
        XCTAssertEqual(
            document.reference(relativeTo: root),
            "file.swift:2:2"
        )
        XCTAssertEqual(
            document.reference(relativeTo: nil),
            "\(url.path):2:2"
        )
    }
}

/// A tiny disk snapshot helper for tests that must capture bytes the same way
/// the document's confirmation does.
enum DiskTestSnapshot {
    static func snapshot(at url: URL) -> DiskSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return DiskSnapshot(bytes: data)
    }
}

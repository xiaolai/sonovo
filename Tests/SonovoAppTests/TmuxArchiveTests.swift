import CryptoKit
import XCTest
@testable import Sonovo

final class TmuxArchiveTests: XCTestCase {
    private func makeStore(
        directory: URL? = nil,
        keyStore: any TmuxArchiveKeyStoring = InMemoryArchiveKeyStore(),
        enabled: Bool = true
    ) -> (TmuxArchiveStore, URL) {
        let url = directory ?? TmuxTestFiles.temporaryDirectory()
        let store = TmuxArchiveStore(
            directory: url,
            keyStore: keyStore,
            isEnabled: enabled
        )
        return (store, url)
    }

    private func metadata(
        id: UUID = UUID(),
        session: TmuxSessionIdentity = TmuxTestData.identity(),
        capturedAt: Date = Date(),
        outcome: TmuxCaptureVerdict = .complete,
        bytes: Int = 100
    ) -> TmuxCaptureMetadata {
        TmuxCaptureMetadata(
            captureID: id,
            session: session,
            sessionName: "sonovo-demo-ab12cd34-1",
            ownershipPath: "/tmp/project",
            ownershipFingerprint: Ownership.verified(
                projectPath: "/tmp/project"
            ).fingerprint,
            capturedAt: capturedAt,
            reason: .captureAndEnd,
            paneLabels: ["window 0 · %1"],
            truncated: outcome == .truncated,
            contentOutcome: outcome,
            byteCount: bytes
        )
    }

    private func capture(
        _ text: String = "canary-content",
        verdict: TmuxCaptureVerdict = .complete
    ) -> TmuxCaptureResult {
        let pane = TmuxCapturePaneResult(
            pane: TmuxPaneAddress(paneID: "%1", label: "window 0"),
            text: text,
            verdict: verdict,
            reason: nil
        )
        return TmuxCaptureResult(
            panes: [pane],
            totalBytes: text.utf8.count,
            verdict: verdict
        )
    }

    func testCommitAndRevealRoundTrip() throws {
        let (store, _) = makeStore()
        let meta = metadata()
        let result = store.commit(
            metadata: meta,
            capture: capture("hello-canary")
        )
        XCTAssertTrue(result.isCommitted)
        XCTAssertTrue(
            store.hasCommittedCompleteCapture(identity: meta.session)
        )
        let revealed = try store.reveal(captureID: meta.captureID)
        XCTAssertEqual(revealed.metadata, meta)
        XCTAssertEqual(revealed.panes.first?.text, "hello-canary")
    }

    func testTruncatedCaptureIsCommittedButNotComplete() {
        let (store, _) = makeStore()
        let meta = metadata(outcome: .truncated)
        let result = store.commit(
            metadata: meta,
            capture: capture("partial", verdict: .truncated)
        )
        XCTAssertTrue(result.isCommitted)
        XCTAssertFalse(
            store.hasCommittedCompleteCapture(identity: meta.session)
        )
        XCTAssertEqual(
            store.latestEntry(identity: meta.session)?.metadata.contentOutcome,
            .truncated
        )
    }

    func testDisabledArchiveWritesNothing() {
        let (store, url) = makeStore(enabled: false)
        let result = store.commit(
            metadata: metadata(),
            capture: capture()
        )
        XCTAssertFalse(result.isCommitted)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertTrue(files.isEmpty)
    }

    func testTamperingFailsClosed() throws {
        let (store, url) = makeStore()
        let meta = metadata()
        XCTAssertTrue(
            store.commit(metadata: meta, capture: capture()).isCommitted
        )
        let file = url.appendingPathComponent(
            "\(meta.captureID.uuidString).enc"
        )
        var data = try Data(contentsOf: file)
        let index = data.count - 1
        data[index] ^= 0xFF
        try data.write(to: file)
        XCTAssertThrowsError(try store.reveal(captureID: meta.captureID))
    }

    func testKeyUnavailableFailsWithoutWriting() {
        let keyStore = InMemoryArchiveKeyStore(
            failure: .keyUnavailable
        )
        let (store, url) = makeStore(keyStore: keyStore)
        let result = store.commit(
            metadata: metadata(),
            capture: capture()
        )
        XCTAssertFalse(result.isCommitted)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertTrue(
            files.allSatisfy { $0.lastPathComponent == "index.json" }
        )
    }

    func testMissingKeyIsNeverSilentlyReplaced() throws {
        let (store, url) = makeStore()
        XCTAssertTrue(
            store.commit(metadata: metadata(), capture: capture())
                .isCommitted
        )
        let emptyKeyStore = InMemoryArchiveKeyStore()
        let reopened = TmuxArchiveStore(
            directory: url,
            keyStore: emptyKeyStore,
            isEnabled: true
        )
        let result = reopened.commit(
            metadata: metadata(),
            capture: capture()
        )
        XCTAssertFalse(result.isCommitted)
        XCTAssertNil(try emptyKeyStore.existingKey())
    }

    func testCrashAfterTempWriteLeavesNoCommitAndReconcileRemovesTemp() throws {
        let directory = TmuxTestFiles.temporaryDirectory()
        let keyStore = InMemoryArchiveKeyStore()
        let (store, _) = makeStore(
            directory: directory,
            keyStore: keyStore
        )
        store.setFailurePoint(.afterTempWrite)
        let meta = metadata()
        let result = store.commit(
            metadata: meta,
            capture: capture()
        )
        XCTAssertFalse(result.isCommitted)
        XCTAssertFalse(
            store.hasCommittedCompleteCapture(identity: meta.session)
        )
        let reopened = TmuxArchiveStore(
            directory: directory,
            keyStore: keyStore,
            isEnabled: true
        )
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(
            files.allSatisfy { !$0.lastPathComponent.hasSuffix(".tmp") }
        )
        XCTAssertFalse(
            reopened.hasCommittedCompleteCapture(identity: meta.session)
        )
    }

    func testCrashAfterRenameIsReconciledFromTheOrphanFile() throws {
        let directory = TmuxTestFiles.temporaryDirectory()
        let keyStore = InMemoryArchiveKeyStore()
        let (store, _) = makeStore(
            directory: directory,
            keyStore: keyStore
        )
        store.setFailurePoint(.afterRenameBeforeIndex)
        let meta = metadata()
        let result = store.commit(
            metadata: meta,
            capture: capture("orphan-canary")
        )
        XCTAssertFalse(result.isCommitted)
        let reopened = TmuxArchiveStore(
            directory: directory,
            keyStore: keyStore,
            isEnabled: true
        )
        XCTAssertTrue(
            reopened.hasCommittedCompleteCapture(identity: meta.session)
        )
        XCTAssertEqual(
            reopened.latestEntry(identity: meta.session)?.reconciled,
            true
        )
        let revealed = try reopened.reveal(captureID: meta.captureID)
        XCTAssertEqual(revealed.panes.first?.text, "orphan-canary")
    }

    func testIndexWriteFailureFailsClosed() throws {
        let directory = TmuxTestFiles.temporaryDirectory()
        let keyStore = InMemoryArchiveKeyStore()
        // A directory at the index path makes the index write fail after
        // the ciphertext rename.
        let store = TmuxArchiveStore(
            directory: directory,
            keyStore: keyStore,
            isEnabled: true
        )
        store.setFailurePoint(.indexWriteFailed)
        let meta = metadata()
        let result = store.commit(metadata: meta, capture: capture())
        XCTAssertFalse(result.isCommitted)
        XCTAssertFalse(
            store.hasCommittedCompleteCapture(identity: meta.session)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory
                    .appendingPathComponent(
                        "\(meta.captureID.uuidString).enc"
                    ).path
            ),
            "The ciphertext rename still happened; only the index failed"
        )
    }

    func testRevealLeavesNoPlaintextFile() throws {
        let (store, directory) = makeStore()
        let canary = "REVEAL-ONLY-IN-MEMORY-\(UUID().uuidString)"
        let meta = metadata()
        XCTAssertTrue(
            store.commit(metadata: meta, capture: capture(canary))
                .isCommitted
        )
        let before = try Set(
            FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).map(\.lastPathComponent)
        )
        let revealed = try store.reveal(captureID: meta.captureID)
        XCTAssertEqual(revealed.panes.first?.text, canary)
        let after = try Set(
            FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).map(\.lastPathComponent)
        )
        XCTAssertEqual(before, after)
    }

    func testIndexEntryWithoutFileIsDroppedOnReconcile() throws {
        let directory = TmuxTestFiles.temporaryDirectory()
        let keyStore = InMemoryArchiveKeyStore()
        let (store, _) = makeStore(
            directory: directory,
            keyStore: keyStore
        )
        let meta = metadata()
        XCTAssertTrue(
            store.commit(metadata: meta, capture: capture()).isCommitted
        )
        try FileManager.default.removeItem(
            at: directory.appendingPathComponent(
                "\(meta.captureID.uuidString).enc"
            )
        )
        XCTAssertFalse(
            store.hasCommittedCompleteCapture(identity: meta.session),
            "A missing file is not a committed capture"
        )
        let reopened = TmuxArchiveStore(
            directory: directory,
            keyStore: keyStore,
            isEnabled: true
        )
        XCTAssertFalse(
            reopened.hasCommittedCompleteCapture(identity: meta.session)
        )
    }

    func testCountCapPurgesOldest() throws {
        let (store, directory) = makeStore()
        store.setLimits(maxCount: 2)
        var ids: [UUID] = []
        for index in 1...3 {
            let meta = metadata(
                capturedAt: Date(
                    timeIntervalSince1970: 1_800_000_000 + Double(index)
                )
            )
            ids.append(meta.captureID)
            XCTAssertTrue(
                store.commit(metadata: meta, capture: capture())
                    .isCommitted
            )
        }
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "enc" }
        XCTAssertEqual(files.count, 2)
        XCTAssertThrowsError(try store.reveal(captureID: ids[0]))
        XCTAssertNoThrow(try store.reveal(captureID: ids[2]))
    }

    func testSavedRetentionIsAppliedBeforeReconcile() throws {
        let directory = TmuxTestFiles.temporaryDirectory()
        let keyStore = InMemoryArchiveKeyStore()
        let old = metadata(
            capturedAt: Date().addingTimeInterval(-60 * 24 * 60 * 60)
        )
        let store = TmuxArchiveStore(
            directory: directory,
            keyStore: keyStore,
            isEnabled: true,
            retentionDays: 90
        )
        XCTAssertTrue(
            store.commit(metadata: old, capture: capture()).isCommitted
        )
        let longPolicy = TmuxArchiveStore(
            directory: directory,
            keyStore: keyStore,
            isEnabled: true,
            retentionDays: 90
        )
        XCTAssertTrue(
            longPolicy.hasCommittedCompleteCapture(identity: old.session),
            "A 90-day policy must survive launch reconciliation"
        )
        let shortPolicy = TmuxArchiveStore(
            directory: directory,
            keyStore: keyStore,
            isEnabled: true,
            retentionDays: 30
        )
        XCTAssertFalse(
            shortPolicy.hasCommittedCompleteCapture(identity: old.session)
        )
    }

    func testRetentionPurgesAndReportsTheCaptureAsNotCommitted() {
        let (store, _) = makeStore()
        store.setRetentionDays(1)
        let old = metadata(
            capturedAt: Date().addingTimeInterval(-2 * 24 * 60 * 60)
        )
        let result = store.commit(metadata: old, capture: capture())
        XCTAssertFalse(result.isCommitted)
        XCTAssertFalse(
            store.hasCommittedCompleteCapture(identity: old.session)
        )
    }

    func testNoPlaintextCanaryAtRest() throws {
        let (store, directory) = makeStore()
        let canary = "SONOVO-PLAINTEXT-CANARY-\(UUID().uuidString)"
        XCTAssertTrue(
            store.commit(
                metadata: metadata(),
                capture: capture(canary)
            ).isCommitted
        )
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        )
        var scanned = 0
        while let url = enumerator?.nextObject() as? URL {
            guard let data = try? Data(contentsOf: url) else { continue }
            scanned += 1
            XCTAssertNil(
                String(data: data, encoding: .utf8)?.range(of: canary),
                "Plaintext capture content appeared in \(url.lastPathComponent)"
            )
        }
        XCTAssertGreaterThan(scanned, 0)
    }

    func testExportWritesOnlyWhenExplicitlyAsked() throws {
        let (store, _) = makeStore()
        let meta = metadata()
        XCTAssertTrue(
            store.commit(metadata: meta, capture: capture("export-me"))
                .isCommitted
        )
        let export = TmuxTestFiles.temporaryDirectory()
            .appendingPathComponent("capture.txt")
        try store.exportPlaintext(captureID: meta.captureID, to: export)
        XCTAssertEqual(
            try String(contentsOf: export, encoding: .utf8),
            "export-me\n"
        )
    }

    func testArchiveOffNeverCreatesAKeyOrFiles() throws {
        let keyStore = InMemoryArchiveKeyStore()
        let (store, url) = makeStore(keyStore: keyStore, enabled: false)
        _ = store.commit(metadata: metadata(), capture: capture())
        XCTAssertNil(try keyStore.existingKey())
        let files = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(files.isEmpty)
    }
}

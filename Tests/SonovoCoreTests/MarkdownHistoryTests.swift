import Foundation
import Testing
@testable import SonovoCore

@Suite("Markdown history")
struct MarkdownHistoryTests {
    private func makeStore(
        perFileQuota: Int = 50
    ) throws -> (MarkdownSnapshotStore, URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonovo-history-\(UUID().uuidString)")
        let root = base.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let store = MarkdownSnapshotStore(
            baseDirectory: base.appendingPathComponent("store"),
            projectRoot: root,
            projectByteQuota: 10 * 1024 * 1024,
            perFileQuota: perFileQuota
        )
        return (store, base)
    }

    @Test("Consecutive autosaves inside the window merge")
    func mergeWindow() async throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let policy = MarkdownHistoryPolicy(mergeWindow: 60)
        let start = Date(timeIntervalSince1970: 1_000)
        let first = await store.recordHistory(
            rawBytes: Data("a\n".utf8),
            relativePath: "a.md",
            kind: .autosave,
            date: start,
            policy: policy
        )
        guard case .captured = first else {
            Issue.record("first save should capture")
            return
        }
        let second = await store.recordHistory(
            rawBytes: Data("b\n".utf8),
            relativePath: "a.md",
            kind: .autosave,
            date: start.addingTimeInterval(30),
            policy: policy
        )
        guard case .merged = second else {
            Issue.record("second autosave should merge")
            return
        }
        let third = await store.recordHistory(
            rawBytes: Data("c\n".utf8),
            relativePath: "a.md",
            kind: .autosave,
            date: start.addingTimeInterval(120),
            policy: policy
        )
        guard case .captured = third else {
            Issue.record("later autosave should capture")
            return
        }
        let records = await store.records(for: "a.md")
        #expect(records.count == 2)
    }

    @Test("Pruning respects count and never evicts pending evidence")
    func pruning() async throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let policy = MarkdownHistoryPolicy(
            mergeWindow: 0,
            maximumCount: 2,
            maximumAge: 365 * 24 * 60 * 60
        )
        let start = Date(timeIntervalSince1970: 1_000)
        var captured: [MarkdownSnapshotRecord] = []
        for index in 0..<4 {
            let result = await store.recordHistory(
                rawBytes: Data("v\(index)\n".utf8),
                relativePath: "a.md",
                kind: .explicit,
                date: start.addingTimeInterval(Double(index)),
                policy: policy
            )
            guard case let .captured(record) = result else {
                Issue.record("capture \(index) failed")
                return
            }
            captured.append(record)
        }
        let remaining = await store.records(for: "a.md")
        #expect(remaining.count <= 2)
        #expect(remaining.count >= 1)
    }

    @Test("The observed queue collapses A→B→C and Keep advances the baseline")
    func observedTransitions() async throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let a = Data("A\n".utf8)
        let b = Data("B\n".utf8)
        let c = Data("C\n".utf8)

        #expect(await store.observe(relativePath: "a.md", diskBytes: a) == nil)
        let first = await store.observe(relativePath: "a.md", diskBytes: b)
        let collapsed = await store.observe(relativePath: "a.md", diskBytes: c)
        let pending = await store.transitions(for: "a.md")
        #expect(pending.count == 1)
        #expect(pending.first?.beforeSha == first?.beforeSha)
        #expect(pending.first?.afterSha == collapsed?.afterSha)

        let decision = await store.decide(
            transitionID: try #require(pending.first?.id),
            keep: true
        )
        #expect(decision == .kept)
        #expect(
            await store.observe(relativePath: "a.md", diskBytes: c) == nil
        )
    }

    @Test("Revert returns A only while the disk is still B")
    func revert() async throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let a = Data("A\r\n".utf8)
        let b = Data("B\r\n".utf8)
        _ = await store.observe(relativePath: "a.md", diskBytes: a)
        let transition = await store.observe(
            relativePath: "a.md",
            diskBytes: b
        )
        let id = try #require(transition?.id)

        let stale = await store.decide(
            transitionID: id,
            keep: false,
            currentDiskBytes: Data("D\r\n".utf8)
        )
        #expect(stale == .staleDisk)

        let reverted = await store.decide(
            transitionID: id,
            keep: false,
            currentDiskBytes: b
        )
        guard case let .revert(bytes) = reverted else {
            Issue.record("expected A's bytes, got \(reverted)")
            return
        }
        #expect(bytes == a)

        let again = await store.decide(
            transitionID: id,
            keep: true
        )
        #expect(again == .alreadyDecided)
    }
}

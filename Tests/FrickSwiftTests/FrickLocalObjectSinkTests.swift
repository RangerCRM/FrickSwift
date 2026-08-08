import XCTest
@testable import FrickSwift

/// Phase 4b write-on-ingest coverage. These tests exercise the real
/// `FrickSQLiteStorage` (a per-test temp-file DB) through `FrickLocalObjectSink`
/// — the exact path the sync socket drives on snapshot/delta/removal — and prove
/// the on-device mirror is complete, current, and losslessly reconstructable.
final class FrickLocalObjectSinkTests: XCTestCase {

    private var tempPaths: [String] = []

    override func tearDown() {
        for path in tempPaths {
            try? FileManager.default.removeItem(atPath: path)
            // Drop the WAL/SHM side files too.
            try? FileManager.default.removeItem(atPath: path + "-wal")
            try? FileManager.default.removeItem(atPath: path + "-shm")
        }
        tempPaths.removeAll()
        super.tearDown()
    }

    // MARK: Helpers

    private func makeStorage() throws -> FrickSQLiteStorage {
        let path = NSTemporaryDirectory() + "frick-sink-\(UUID().uuidString).sqlite"
        tempPaths.append(path)
        return try FrickSQLiteStorage(path: path)
    }

    /// Build a record, always carrying the socket-supplied `id` field.
    private func record(type: String, id: String, _ fields: [String: String] = [:]) -> FrickObjectRecord {
        var value = fields
        value["id"] = id
        return FrickObjectRecord(type: type, id: id, value: value)
    }

    /// Load every cached row of `type` and reconstruct it back into a record,
    /// keyed by id — the round trip a `loadAllObjects` consumer performs.
    private func loadReconstructed(
        _ storage: FrickSQLiteStorage,
        type: String
    ) throws -> [String: FrickObjectRecord] {
        var out: [String: FrickObjectRecord] = [:]
        for (id, json) in try storage.loadAllObjects(type: type) {
            out[id] = FrickObjectRecord.fromCachedJSON(type: type, id: id, json: json)
        }
        return out
    }

    // MARK: 1. Round-trip fidelity

    func testRoundTripPreservesEveryFieldAndAbsentOptionalsStayAbsent() throws {
        let storage = try makeStorage()
        let sink = FrickLocalObjectSink(storage: storage)

        // A present field, a stringified bool, a stringified number, and an
        // explicitly-empty-but-present field. `subtitle` is deliberately ABSENT
        // (an optional the server left nil) — it must NOT come back as "".
        let original = record(type: "Account", id: "acc-1", [
            "name": "Ranger Technologies",
            "isFavorite": "true",
            "headcount": "42",
            "notes": "",
        ])

        sink.applyDelta([original])

        let reconstructed = try XCTUnwrap(loadReconstructed(storage, type: "Account")["acc-1"])

        XCTAssertEqual(reconstructed.type, "Account")
        XCTAssertEqual(reconstructed.id, "acc-1")
        XCTAssertEqual(reconstructed.value, original.value, "every field must survive the round trip verbatim")

        // The present-but-empty field survives as "".
        XCTAssertEqual(reconstructed.value["notes"], "")

        // The absent optional must NOT resurrect as an empty-string stub.
        XCTAssertNil(reconstructed.value["subtitle"], "an absent optional must not become an empty-string stub")

        // A present field must not be lost.
        XCTAssertEqual(reconstructed.value["name"], "Ranger Technologies")
        XCTAssertEqual(reconstructed.value["isFavorite"], "true")
        XCTAssertEqual(reconstructed.value["headcount"], "42")
    }

    // MARK: 2. Snapshot completeness

    func testSnapshotDropsRowsAbsentFromLaterSnapshotAndLeavesOtherTypes() throws {
        let storage = try makeStorage()
        let sink = FrickLocalObjectSink(storage: storage)

        // An unrelated type that must never be touched by Account snapshots.
        sink.applySnapshot([record(type: "Contact", id: "con-1", ["name": "Ada"])])

        sink.applySnapshot([
            record(type: "Account", id: "A", ["name": "a"]),
            record(type: "Account", id: "B", ["name": "b"]),
            record(type: "Account", id: "C", ["name": "c"]),
        ])
        XCTAssertEqual(Set(try loadReconstructed(storage, type: "Account").keys), ["A", "B", "C"])

        // A second, authoritative snapshot omitting B — B must be evicted.
        sink.applySnapshot([
            record(type: "Account", id: "A", ["name": "a2"]),
            record(type: "Account", id: "C", ["name": "c2"]),
        ])

        let accounts = try loadReconstructed(storage, type: "Account")
        XCTAssertEqual(Set(accounts.keys), ["A", "C"], "B must be gone — it was absent from the authoritative snapshot")
        XCTAssertEqual(accounts["A"]?.value["name"], "a2", "surviving rows must be updated to the snapshot value")

        // The sibling type is untouched by the Account snapshots.
        XCTAssertEqual(Set(try loadReconstructed(storage, type: "Contact").keys), ["con-1"])
    }

    // MARK: 3. Delta upsert

    func testDeltaMutatesExistingRowAndInsertsNewRow() throws {
        let storage = try makeStorage()
        let sink = FrickLocalObjectSink(storage: storage)

        sink.applySnapshot([record(type: "Account", id: "A", ["name": "old"])])

        // Mutate A, add a brand-new D.
        sink.applyDelta([
            record(type: "Account", id: "A", ["name": "new"]),
            record(type: "Account", id: "D", ["name": "d"]),
        ])

        let accounts = try loadReconstructed(storage, type: "Account")
        XCTAssertEqual(Set(accounts.keys), ["A", "D"])
        XCTAssertEqual(accounts["A"]?.value["name"], "new", "delta must mutate the existing row in place")
        XCTAssertEqual(accounts["D"]?.value["name"], "d", "delta must insert the new row")
    }

    // MARK: 4. Removal

    func testRemovalDeletesOnlyTheNamedRow() throws {
        let storage = try makeStorage()
        let sink = FrickLocalObjectSink(storage: storage)

        sink.applySnapshot([
            record(type: "Account", id: "A", ["name": "a"]),
            record(type: "Account", id: "B", ["name": "b"]),
            record(type: "Account", id: "C", ["name": "c"]),
        ])

        sink.applyRemovals([FrickObjectRemoval(type: "Account", id: "A")])

        XCTAssertEqual(Set(try loadReconstructed(storage, type: "Account").keys), ["B", "C"], "only A must be removed")
    }

    // MARK: 5. Type isolation

    func testOperationsOnOneTypeNeverTouchAnother() throws {
        let storage = try makeStorage()
        let sink = FrickLocalObjectSink(storage: storage)

        sink.applySnapshot([
            record(type: "Account", id: "A", ["name": "a"]),
            record(type: "Contact", id: "A", ["name": "contact-a"]),
        ])

        // Same id "A" in two types must be independent.
        sink.applyRemovals([FrickObjectRemoval(type: "Account", id: "A")])
        XCTAssertTrue(try loadReconstructed(storage, type: "Account").isEmpty)
        XCTAssertEqual(try loadReconstructed(storage, type: "Contact")["A"]?.value["name"], "contact-a")

        // A delta on Contact must not create/alter Account rows.
        sink.applyDelta([record(type: "Contact", id: "B", ["name": "contact-b"])])
        XCTAssertTrue(try loadReconstructed(storage, type: "Account").isEmpty)
        XCTAssertEqual(Set(try loadReconstructed(storage, type: "Contact").keys), ["A", "B"])
    }

    // MARK: 6. Encoding consistency — legacy typed-DTO tolerance + convergence

    /// Proves the encoding-consistency reasoning: a row written the *legacy*
    /// way (`saveObjectData` with typed DTO JSON — booleans as `true`, numbers as
    /// numbers) is still reconstructable via `fromCachedJSON`, and the next
    /// authoritative snapshot converges it to the canonical stringified form.
    func testLegacyTypedJSONRowIsToleratedThenConvergedBySnapshot() throws {
        let storage = try makeStorage()
        let sink = FrickLocalObjectSink(storage: storage)

        struct AccountDTO: Codable {
            let id: String
            let name: String
            let isFavorite: Bool
            let headcount: Int
        }
        let dto = AccountDTO(id: "A", name: "Ranger", isFavorite: true, headcount: 42)
        // Legacy write path stores TYPED DTO JSON at some server version (7).
        try storage.saveObjectData(type: "Account", id: "A", data: try JSONEncoder().encode(dto), version: 7)

        // fromCachedJSON tolerates the typed shape, stringifying each field to
        // the socket wire form.
        let legacy = try XCTUnwrap(loadReconstructed(storage, type: "Account")["A"])
        XCTAssertEqual(legacy.value["name"], "Ranger")
        XCTAssertEqual(legacy.value["isFavorite"], "true", "a JSON boolean must stringify to \"true\", not \"1\"")
        XCTAssertEqual(legacy.value["headcount"], "42")

        // The version stamped by the legacy write is intact...
        XCTAssertEqual(try storage.loadObjectVersion(type: "Account", id: "A"), 7)

        // ...and an ingest upsert (echo delta) preserves that version while
        // converging the payload to the canonical [String:String] form.
        sink.applyDelta([record(type: "Account", id: "A", ["name": "Ranger", "isFavorite": "true", "headcount": "42"])])
        XCTAssertEqual(
            try storage.loadObjectVersion(type: "Account", id: "A"), 7,
            "ingest upsert must NOT clobber a version a prior writeObject recorded"
        )

        // The row now decodes cleanly as the canonical [String:String] shape.
        let converged = try storage.loadAllObjects(type: "Account").first { $0.id == "A" }
        let asStrings = try JSONDecoder().decode([String: String].self, from: try XCTUnwrap(converged).json)
        XCTAssertEqual(asStrings["isFavorite"], "true")
    }

    // MARK: 7. Empty snapshot never clears

    func testEmptySnapshotLeavesCacheUntouched() throws {
        let storage = try makeStorage()
        let sink = FrickLocalObjectSink(storage: storage)

        sink.applySnapshot([record(type: "Account", id: "A", ["name": "a"])])
        sink.applySnapshot([])  // e.g. a sibling type's empty snapshot

        XCTAssertEqual(Set(try loadReconstructed(storage, type: "Account").keys), ["A"])
    }
}

import Foundation
import os

// MARK: - FrickLocalObjectSink

/// Persists socket-delivered object records into `FrickStorage`'s
/// `local_objects` table as they arrive, so `FrickSQLiteStorage.loadAllObjects`
/// returns the COMPLETE, current dataset even with no live socket.
///
/// ## Why this exists (Phase 4b, "free = local-only")
///
/// The sync socket applies snapshots/deltas to a `FrickStore`'s in-memory
/// `items` only — it never wrote them to disk. `local_objects` was populated
/// solely by the REST `writeObject`/`fetchObjects` paths, so a client that only
/// ever received data over the socket had an EMPTY local cache. This sink closes
/// that gap: every ingested snapshot/delta/removal is mirrored to disk.
///
/// ## Canonical stored encoding
///
/// A `FrickObjectRecord.value` is already a flat `[String: String]` (every field
/// stringified by the socket's decoder — booleans as `"true"`/`"false"`, numbers
/// as their string form, absent fields simply absent). This sink stores exactly
/// that dictionary as JSON (`JSONEncoder().encode(record.value)`), so the round
/// trip back to a `FrickObjectRecord` is byte-faithful and lossless: a nil/absent
/// optional stays absent (it does NOT resurrect as an empty-string stub), and a
/// present field is preserved verbatim. Use `FrickObjectRecord.fromCachedJSON`
/// to reconstruct.
///
/// This differs from `writeObject`/`fetchObjects`, which store *typed DTO JSON*
/// (booleans as `true`/`false`, numbers as numbers). Those two shapes coexist in
/// the same column only transiently: the authoritative snapshot the server sends
/// on every (re)connect covers ALL rows of each subscribed type, and this sink
/// upserts each via `INSERT ... ON CONFLICT DO UPDATE`, converging any legacy
/// typed-JSON row to the canonical stringified form. `fromCachedJSON` also
/// tolerates the legacy shape, so a consumer never trips over an un-converged
/// row in the window before the first snapshot lands.
struct FrickLocalObjectSink: Sendable {

    private let storage: FrickStorage
    private static let log = Logger(subsystem: "FrickSwift", category: "local-object-sink")

    init(storage: FrickStorage) {
        self.storage = storage
    }

    // MARK: Ingest

    /// Reconcile the local cache to an authoritative snapshot. For EACH type the
    /// snapshot carries, upserts its rows and deletes any local row of that type
    /// absent from the snapshot (the snapshot is complete for the types it spans;
    /// completeness is essential or a stale/revoked row leaks). Types the
    /// snapshot does not mention are left untouched — an empty or sibling-type
    /// snapshot can't wrongly clear a type it isn't authoritative for.
    func applySnapshot(_ records: [FrickObjectRecord]) {
        guard !records.isEmpty else { return }

        var idsByType: [String: [String]] = [:]
        for record in records {
            idsByType[record.type, default: []].append(record.id)
            upsert(record)
        }

        for (type, ids) in idsByType {
            do {
                try storage.deleteObjectsOfType(type, keepingIds: ids)
            } catch {
                Self.log.error("snapshot reconcile delete failed for \(type, privacy: .public): \(error, privacy: .public)")
            }
        }
    }

    /// Apply an incremental upsert batch — merge each row in, remove nothing.
    func applyDelta(_ records: [FrickObjectRecord]) {
        for record in records {
            upsert(record)
        }
    }

    /// Apply a removal batch — delete each row by `(type, id)`.
    func applyRemovals(_ removals: [FrickObjectRemoval]) {
        for removal in removals {
            do {
                try storage.deleteObjectData(type: removal.type, id: removal.id)
            } catch {
                Self.log.error("removal delete failed for \(removal.type, privacy: .public)/\(removal.id, privacy: .public): \(error, privacy: .public)")
            }
        }
    }

    // MARK: Internals

    private func upsert(_ record: FrickObjectRecord) {
        do {
            let data = try JSONEncoder().encode(record.value)
            try storage.upsertIngestedObject(type: record.type, id: record.id, data: data)
        } catch {
            Self.log.error("ingest upsert failed for \(record.type, privacy: .public)/\(record.id, privacy: .public): \(error, privacy: .public)")
        }
    }
}

// MARK: - Reconstruction

public extension FrickObjectRecord {

    /// Reconstruct a `FrickObjectRecord` from a `local_objects` JSON blob (an
    /// `(id, json)` pair as returned by `FrickSQLiteStorage.loadAllObjects`).
    ///
    /// The canonical rows written by socket ingest are a flat `[String: String]`
    /// object and round-trip exactly. Rows written by the REST
    /// `writeObject`/`fetchObjects` paths are *typed DTO JSON*; those are
    /// tolerated by decoding generically and stringifying each top-level field to
    /// match the socket's wire form (booleans → `"true"`/`"false"`, integers → their
    /// digits, `null` → dropped, nested containers → compact JSON). Number
    /// formatting for the typed-DTO fallback is best-effort — those rows converge
    /// to the canonical form on the next snapshot regardless.
    ///
    /// Always guarantees `value["id"] == id`. Returns `nil` only if `json` is not
    /// a JSON object at all.
    static func fromCachedJSON(type: String, id: String, json: Data) -> FrickObjectRecord? {
        if let strings = try? JSONDecoder().decode([String: String].self, from: json) {
            var value = strings
            value["id"] = id
            return FrickObjectRecord(type: type, id: id, value: value)
        }

        guard let object = try? JSONSerialization.jsonObject(with: json),
              let dict = object as? [String: Any] else {
            return nil
        }

        var value: [String: String] = [:]
        for (key, raw) in dict {
            if let string = Self.stringifyCachedField(raw) {
                value[key] = string
            }
        }
        value["id"] = id

        return FrickObjectRecord(type: type, id: id, value: value)
    }

    /// Stringify one top-level JSON field to the socket's `[String: String]` wire
    /// form. Returns `nil` for JSON `null` so an absent/nil optional is dropped
    /// rather than resurrected as an empty-string stub.
    private static func stringifyCachedField(_ raw: Any) -> String? {
        switch raw {
        case is NSNull:
            return nil

        case let string as String:
            return string

        case let number as NSNumber:
            // Distinguish a JSON boolean from a numeric 0/1: NSNumber wraps both,
            // but a boolean's objCType is "c" (the __NSCFBoolean encoding).
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            if number.stringValue.hasSuffix(".0") {
                // Whole doubles print as integers on the wire ("3", not "3.0").
                return String(number.intValue)
            }
            return number.stringValue

        default:
            if let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]),
               let string = String(data: data, encoding: .utf8) {
                return string
            }
            return nil
        }
    }
}

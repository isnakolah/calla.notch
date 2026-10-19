import Foundation
import SQLite3

/// Row-level backup of the store, for the calla backend.
///
/// Generic on purpose: every table with a `call_id` column (and `call` itself)
/// belongs to a call and travels with that call; every other table is
/// device-wide and travels in the device snapshot. A table added by a future
/// migration is therefore backed up without anyone remembering to list it.
///
/// One JSON object per row, keyed by column name. BLOBs (voiceprint and chunk
/// embeddings) are `{"$b64": "..."}` so the format stays plain JSONL.
///
/// FTS: an external-content index (`knowledge_fts`) is skipped and rebuilt
/// after a restore; a contentful one (`tutor_fts`) is dumped through its
/// virtual table. FTS shadow tables are never touched directly.
public struct StoreBackupTables: Sendable {
    /// Table name to JSONL.
    public var tables: [String: Data]
    public var schemaVersion: Int

    public init(tables: [String: Data], schemaVersion: Int) {
        self.tables = tables
        self.schemaVersion = schemaVersion
    }
}

public enum StoreBackupError: Error, LocalizedError, Equatable {
    case newerSchema(Int, local: Int)
    case badRow(String)

    public var errorDescription: String? {
        switch self {
        case let .newerSchema(theirs, local): "Backup schema \(theirs) is newer than this build's \(local); update calla.notch first"
        case let .badRow(table): "Backup row for \(table) is not a JSON object"
        }
    }
}

extension CallaStore {
    public var schemaVersion: Int { Schema.current }

    /// Rows belonging to one call, from every call-owned table.
    public func backupRows(forCall callID: String) throws -> StoreBackupTables {
        var out: [String: Data] = [:]
        for table in try backupLayout().callTables {
            let column = table == "call" ? "id" : "call_id"
            let data = try dumpRows(table: table, where: "\(quoted(column)) = ?", [.text(callID)])
            if !data.isEmpty { out[table] = data }
        }
        return StoreBackupTables(tables: out, schemaVersion: Schema.current)
    }

    /// Every device-wide table: voiceprints, knowledge, tutor state, meta.
    public func backupDeviceRows() throws -> StoreBackupTables {
        var out: [String: Data] = [:]
        let layout = try backupLayout()
        for table in layout.deviceTables {
            let rowid = layout.contentfulFTS.contains(table)
            let data = try dumpRows(table: table, where: nil, [], includeRowID: rowid)
            if !data.isEmpty { out[table] = data }
        }
        return StoreBackupTables(tables: out, schemaVersion: Schema.current)
    }

    /// Inserts backed-up rows that are not already present. Never overwrites a
    /// local row, so restoring onto a Mac that has kept working is safe.
    /// Columns this build does not know are dropped; columns the backup lacks
    /// take their defaults. Returns rows inserted per table.
    @discardableResult
    public func restoreRows(_ backup: StoreBackupTables) throws -> [String: Int] {
        guard backup.schemaVersion <= Schema.current else {
            throw StoreBackupError.newerSchema(backup.schemaVersion, local: Schema.current)
        }
        let layout = try backupLayout()
        let known = Set(layout.callTables + layout.deviceTables)
        let order = try dependencyOrder(backup.tables.keys.filter { known.contains($0) })
        var inserted: [String: Int] = [:]
        try database.transaction {
            for table in order {
                guard let data = backup.tables[table] else { continue }
                let columns = Set(try database.query("SELECT name FROM pragma_table_xinfo(?)", [.text(table)]) { $0.string(0) })
                    .union(layout.contentfulFTS.contains(table) ? ["rowid"] : [])
                var count = 0
                for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
                    guard let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                        throw StoreBackupError.badRow(table)
                    }
                    let pairs = object.filter { columns.contains($0.key) }.sorted { $0.key < $1.key }
                    guard !pairs.isEmpty else { continue }
                    let names = pairs.map { quoted($0.key) }.joined(separator: ", ")
                    let marks = Array(repeating: "?", count: pairs.count).joined(separator: ", ")
                    try database.run("INSERT OR IGNORE INTO \(quoted(table)) (\(names)) VALUES (\(marks))",
                                     pairs.map { Self.sqliteValue($0.value) })
                    count += database.changes
                }
                inserted[table] = count
            }
            for fts in layout.externalFTS {
                try database.run("INSERT INTO \(quoted(fts))(\(quoted(fts))) VALUES('rebuild')")
            }
        }
        return inserted
    }

    // MARK: - Layout

    private struct BackupLayout {
        var callTables: [String] = []
        var deviceTables: [String] = []
        var externalFTS: [String] = []
        var contentfulFTS: Set<String> = []
    }

    private func backupLayout() throws -> BackupLayout {
        let entries = try database.query(
            "SELECT name, COALESCE(sql, '') FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
        ) { ($0.string(0), $0.string(1)) }
        var layout = BackupLayout()
        let virtual = entries.filter { $0.1.uppercased().hasPrefix("CREATE VIRTUAL TABLE") }
        let shadowPrefixes = virtual.map { $0.0 + "_" }
        for (name, sql) in virtual {
            if sql.range(of: "content\\s*=\\s*'[^']+'", options: .regularExpression) != nil {
                layout.externalFTS.append(name)
            } else {
                layout.contentfulFTS.insert(name)
                layout.deviceTables.append(name)
            }
        }
        for (name, sql) in entries where !sql.uppercased().hasPrefix("CREATE VIRTUAL TABLE") {
            if shadowPrefixes.contains(where: { name.hasPrefix($0) }) { continue }
            let columns = try database.query("SELECT name FROM pragma_table_info(?)", [.text(name)]) { $0.string(0) }
            if name == "call" || columns.contains("call_id") {
                layout.callTables.append(name)
            } else {
                layout.deviceTables.append(name)
            }
        }
        return layout
    }

    /// Parents before children, from the schema's own foreign keys.
    private func dependencyOrder(_ tables: [String]) throws -> [String] {
        let set = Set(tables)
        var parents: [String: Set<String>] = [:]
        for table in tables {
            let refs = try database.query("SELECT \"table\" FROM pragma_foreign_key_list(?)", [.text(table)]) { $0.string(0) }
            parents[table] = Set(refs).intersection(set).subtracting([table])
        }
        var ordered: [String] = []
        var placed = Set<String>()
        while ordered.count < tables.count {
            let ready = tables.filter { !placed.contains($0) && (parents[$0] ?? []).isSubset(of: placed) }.sorted()
            guard !ready.isEmpty else {
                ordered += tables.filter { !placed.contains($0) }.sorted() // a cycle: let FK checks decide
                break
            }
            ordered += ready
            placed.formUnion(ready)
        }
        return ordered
    }

    // MARK: - Rows

    private func dumpRows(table: String, where clause: String?, _ bindings: [SQLiteValue], includeRowID: Bool = false) throws -> Data {
        let columns = try database.query("SELECT name FROM pragma_table_info(?)", [.text(table)]) { $0.string(0) }
        let selected = (includeRowID ? ["rowid"] : []) + columns
        let sql = "SELECT \(selected.map(quoted).joined(separator: ", ")) FROM \(quoted(table))"
            + (clause.map { " WHERE \($0)" } ?? "")
            + (includeRowID ? " ORDER BY rowid" : "")
        var out = Data()
        let rows: [[String: Any]] = try database.query(sql, bindings) { row in
            var object: [String: Any] = [:]
            for (index, name) in selected.enumerated() {
                object[name] = Self.jsonValue(row, Int32(index))
            }
            return object
        }
        for object in rows {
            out.append(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            out.append(UInt8(ascii: "\n"))
        }
        return out
    }

    private static func jsonValue(_ row: SQLiteRow, _ index: Int32) -> Any {
        switch sqlite3_column_type(row.statement, index) {
        case SQLITE_INTEGER: return row.int(index)
        case SQLITE_FLOAT: return row.double(index)
        case SQLITE_TEXT: return row.string(index)
        case SQLITE_BLOB: return ["$b64": (row.blob(index) ?? Data()).base64EncodedString()]
        default: return NSNull()
        }
    }

    private static func sqliteValue(_ value: Any) -> SQLiteValue {
        switch value {
        case is NSNull: return .null
        case let number as NSNumber:
            // JSONSerialization hands back NSNumber for both; keep integers integral.
            if CFNumberIsFloatType(number) { return .double(number.doubleValue) }
            return .int(number.int64Value)
        case let string as String: return .text(string)
        case let object as [String: Any]:
            if let b64 = object["$b64"] as? String, let data = Data(base64Encoded: b64) { return .blob(data) }
            return .null
        default: return .null
        }
    }
}

private func quoted(_ identifier: String) -> String {
    "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}

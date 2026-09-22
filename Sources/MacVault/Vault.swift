import Foundation
import Darwin
import CryptoKit

/// A regular file discovered below the import source, fully inspected during
/// the pre-flight phase before anything is written.
struct PlannedEntry: Hashable {
    let relativePath: String
    let absoluteSourcePath: String
    let sha256: String
    let size: Int64
}

/// Failures that abort an import. `entry` carries the path relative to the
/// source root whenever the problem is a specific entry, so callers can report
/// exactly what was rejected.
enum VaultError: Error, CustomStringConvertible {
    case entry(relativePath: String, reason: String)
    case general(String)

    var description: String {
        switch self {
        case let .entry(relativePath, reason):
            return "\"\(relativePath)\": \(reason)"
        case let .general(message):
            return message
        }
    }
}

enum Vault {
    static let catalogName = "catalog.sqlite3"
    static let objectsName = "objects"

    /// Creates `<vault>/catalog.sqlite3` and `<vault>/objects`. Re-running on
    /// an existing vault is a no-op: existing contents are never removed.
    static func initialize(vaultPath: String) throws {
        let manager = FileManager.default
        let vault = (vaultPath as NSString).standardizingPath

        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: vault, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw VaultError.general("vault path is not a directory: \(vault)")
            }
        } else {
            try manager.createDirectory(atPath: vault, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o755])
        }

        let objects = (vault as NSString).appendingPathComponent(objectsName)
        if !manager.fileExists(atPath: objects, isDirectory: &isDirectory) {
            try manager.createDirectory(atPath: objects, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o755])
        } else if !isDirectory.boolValue {
            throw VaultError.general("objects path is not a directory: \(objects)")
        }

        let database = try openCatalog(vault: vault, create: true)
        try createSchema(database)
    }

    struct ImportResult: Encodable {
        let imported: Int
        let unchanged: Int
        let reusedObjects: Int
    }

    /// Recursively receives regular files below `sourcePath` into the vault.
    /// The pass is all-or-nothing: every entry is inspected and hashed first,
    /// new blobs are streamed through a private staging directory, and the
    /// catalog rows are upserted in one transaction. Any failure rolls the
    /// whole import back and removes the staging area.
    static func `import`(vaultPath: String, sourcePath: String) throws -> ImportResult {
        let manager = FileManager.default
        let vault = (vaultPath as NSString).standardizingPath
        let source = (sourcePath as NSString).standardizingPath

        try requireInitialized(vault: vault)

        var sourceIsDirectory: ObjCBool = false
        guard manager.fileExists(atPath: source, isDirectory: &sourceIsDirectory),
              sourceIsDirectory.boolValue else {
            throw VaultError.general("source directory not found: \(source)")
        }

        // Phase 1 — pre-flight: walk the whole tree and hash every file before
        // touching the vault.
        let planned = try scan(source: source)

        let database = try openCatalog(vault: vault, create: false)
        let existing = try fetchEntries(database: database)
        var existingByPath: [String: CatalogEntry] = [:]
        for entry in existing {
            existingByPath[entry.relativePath] = entry
        }

        var unchanged = 0
        var toUpsert: [PlannedEntry] = []
        for entry in planned {
            if let current = existingByPath[entry.relativePath], current.sha256 == entry.sha256 {
                unchanged += 1
            } else {
                toUpsert.append(entry)
            }
        }

        // Content is deduplicated by hash: a blob is written once even when
        // several paths share it.
        let objects = (vault as NSString).appendingPathComponent(objectsName)
        var representative: [String: PlannedEntry] = [:]
        for entry in toUpsert {
            representative[entry.sha256] = entry
        }

        var blobsPresent = Set<String>()
        var blobsMissing: [String] = []
        for sha in representative.keys {
            let objectPath = (objects as NSString).appendingPathComponent(sha)
            if manager.fileExists(atPath: objectPath) {
                blobsPresent.insert(sha)
            } else {
                blobsMissing.append(sha)
            }
        }
        let reusedObjects = blobsPresent.count

        // Phase 2 — stage every new blob under a private 0700 directory.
        let staging = try makeStagingDirectory(vault: vault)
        var publishedBlobs: [String] = []

        do {
            for sha in blobsMissing.sorted() {
                let entry = representative[sha]!
                let stagedPath = (staging as NSString).appendingPathComponent(sha)
                do {
                    try stageBlob(from: entry.absoluteSourcePath,
                                  into: stagedPath,
                                  expectedSHA256: sha,
                                  relativePath: entry.relativePath)
                } catch let error as VaultError {
                    throw error
                } catch {
                    throw VaultError.entry(relativePath: entry.relativePath,
                                           reason: "cannot stage file: \(error.localizedDescription)")
                }
            }

            // Phase 3 — publish blobs and update the catalog atomically.
            try withTransaction(database) {
                for sha in blobsMissing.sorted() {
                    let entry = representative[sha]!
                    let destination = (objects as NSString).appendingPathComponent(sha)
                    let stagedPath = (staging as NSString).appendingPathComponent(sha)
                    if rename(stagedPath, destination) != 0 {
                        throw VaultError.entry(
                            relativePath: entry.relativePath,
                            reason: "cannot store object: \(String(cString: strerror(errno)))")
                    }
                    publishedBlobs.append(destination)
                }

                let insert = try database.prepare(
                    "INSERT INTO entries (relative_path, sha256, size) VALUES (?, ?, ?)")
                let update = try database.prepare(
                    "UPDATE entries SET sha256 = ?, size = ? WHERE relative_path = ?")

                for entry in toUpsert.sorted(by: { $0.relativePath < $1.relativePath }) {
                    do {
                        if existingByPath[entry.relativePath] != nil {
                            try update.bind(entry.sha256, entry.size, entry.relativePath)
                            guard try update.step() == false, database.changes == 1 else {
                                throw VaultError.entry(
                                    relativePath: entry.relativePath,
                                    reason: "catalog update did not affect exactly one row")
                            }
                        } else {
                            try insert.bind(entry.relativePath, entry.sha256, entry.size)
                            _ = try insert.step()
                            insert.reset()
                        }
                    } catch let error as SQLiteError {
                        throw VaultError.entry(relativePath: entry.relativePath,
                                               reason: "catalog commit failed: \(error)")
                    }
                }
            }
        } catch {
            // Restore the original state: the transaction helper has rolled
            // the catalog back; remove any blobs this import published and
            // clear the staging area.
            for path in publishedBlobs {
                try? manager.removeItem(atPath: path)
            }
            try? manager.removeItem(atPath: staging)
            throw error
        }

        try? manager.removeItem(atPath: staging)
        return ImportResult(imported: toUpsert.count,
                            unchanged: unchanged,
                            reusedObjects: reusedObjects)
    }

    struct CatalogEntry: Encodable {
        let id: Int64
        let relativePath: String
        let sha256: String
        let size: Int64
    }

    /// Lists catalog entries ordered by relative path then id, optionally
    /// filtered by a case-insensitive substring match on the file name.
    static func list(vaultPath: String, nameSubstring: String?) throws -> [CatalogEntry] {
        let vault = (vaultPath as NSString).standardizingPath
        try requireInitialized(vault: vault)
        let database = try openCatalog(vault: vault, create: false)

        let statement = try database.prepare(
            "SELECT id, relative_path, sha256, size FROM entries ORDER BY relative_path ASC, id ASC")
        var entries: [CatalogEntry] = []
        while try statement.step() {
            entries.append(CatalogEntry(
                id: statement.int64(0),
                relativePath: statement.string(1),
                sha256: statement.string(2),
                size: statement.int64(3)))
        }

        guard let needle = nameSubstring else { return entries }
        return entries.filter { entry in
            let fileName = (entry.relativePath as NSString).lastPathComponent
            return fileName.range(of: needle, options: .caseInsensitive) != nil
        }
    }

    // MARK: - Helpers

    private static func requireInitialized(vault: String) throws {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: vault, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw VaultError.general("vault directory not found: \(vault)")
        }
        let catalog = (vault as NSString).appendingPathComponent(catalogName)
        guard manager.fileExists(atPath: catalog, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw VaultError.general("vault is not initialized (run `macvault init`): \(vault)")
        }
        let objects = (vault as NSString).appendingPathComponent(objectsName)
        guard manager.fileExists(atPath: objects, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw VaultError.general("vault is not initialized (run `macvault init`): \(vault)")
        }
    }

    private static func openCatalog(vault: String, create: Bool) throws -> Database {
        let catalog = (vault as NSString).appendingPathComponent(catalogName)
        do {
            return try Database(path: catalog)
        } catch let error as SQLiteError {
            throw VaultError.general("cannot open catalog: \(error)")
        }
    }

    private static func createSchema(_ database: Database) throws {
        do {
            try database.exec("""
            CREATE TABLE IF NOT EXISTS entries (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                relative_path TEXT NOT NULL UNIQUE,
                sha256 TEXT NOT NULL,
                size INTEGER NOT NULL
            )
            """)
            try database.exec("""
            CREATE INDEX IF NOT EXISTS idx_entries_relative_path
            ON entries (relative_path)
            """)
        } catch let error as SQLiteError {
            throw VaultError.general("cannot initialize catalog schema: \(error)")
        }
    }

    private static func fetchEntries(database: Database) throws -> [CatalogEntry] {
        let statement = try database.prepare("SELECT id, relative_path, sha256, size FROM entries")
        var entries: [CatalogEntry] = []
        while try statement.step() {
            entries.append(CatalogEntry(
                id: statement.int64(0),
                relativePath: statement.string(1),
                sha256: statement.string(2),
                size: statement.int64(3)))
        }
        return entries
    }

    /// Recursively collects regular files below `source`, rejecting symbolic
    /// links, special files, unreadable files and suspicious paths. Every
    /// surviving file is hashed before the function returns.
    private static func scan(source: String) throws -> [PlannedEntry] {
        var planned: [PlannedEntry] = []
        try walk(directory: source, prefix: "", into: &planned)
        return planned
    }

    private static func walk(directory: String, prefix: String,
                             into planned: inout [PlannedEntry]) throws {
        let manager = FileManager.default
        let names: [String]
        do {
            names = try manager.contentsOfDirectory(atPath: directory)
        } catch {
            let rel = prefix.isEmpty ? "." : prefix
            throw VaultError.entry(relativePath: rel,
                                   reason: "cannot read directory: \(error.localizedDescription)")
        }

        for name in names.sorted() {
            let relativePath = prefix.isEmpty ? name : "\(prefix)/\(name)"
            // Defense in depth against path traversal even though enumeration
            // can only yield real on-disk names.
            if name == "." || name == ".." || name.contains("\0")
                || relativePath.hasPrefix("/") {
                throw VaultError.entry(relativePath: relativePath, reason: "path escapes the source directory")
            }
            let fullPath = (directory as NSString).appendingPathComponent(name)

            var status = stat()
            if lstat(fullPath, &status) != 0 {
                throw VaultError.entry(relativePath: relativePath,
                                       reason: "cannot stat file: \(String(cString: strerror(errno)))")
            }

            switch status.st_mode & S_IFMT {
            case S_IFLNK:
                throw VaultError.entry(relativePath: relativePath,
                                       reason: "symbolic links are not supported")
            case S_IFDIR:
                try walk(directory: fullPath, prefix: relativePath, into: &planned)
            case S_IFREG:
                if access(fullPath, R_OK) != 0 {
                    throw VaultError.entry(relativePath: relativePath,
                                           reason: "file is not readable")
                }
                let hash: (sha256: String, size: Int64)
                do {
                    hash = try FileHash.sha256AndSize(of: fullPath)
                } catch {
                    throw VaultError.entry(relativePath: relativePath,
                                           reason: "cannot read file: \(error.localizedDescription)")
                }
                if hash.size != status.st_size {
                    throw VaultError.entry(relativePath: relativePath,
                                           reason: "file changed while it was being read")
                }
                planned.append(PlannedEntry(relativePath: relativePath,
                                            absoluteSourcePath: fullPath,
                                            sha256: hash.sha256,
                                            size: hash.size))
            default:
                throw VaultError.entry(relativePath: relativePath,
                                       reason: "not a regular file")
            }
        }
    }

    private static func makeStagingDirectory(vault: String) throws -> String {
        let template = (vault as NSString).appendingPathComponent(".staging-XXXXXX")
        var bytes = [CChar](template.utf8CString)
        let created = bytes.withUnsafeMutableBufferPointer { buffer -> String? in
            guard let result = mkdtemp(buffer.baseAddress) else { return nil }
            return String(cString: result)
        }
        guard let staging = created else {
            throw VaultError.general("cannot create staging area: \(String(cString: strerror(errno)))")
        }
        return staging
    }

    /// Streams a source file into the staging area, hashing the bytes as they
    /// pass through so a change between pre-flight and commit aborts the import.
    private static func stageBlob(from sourcePath: String, into stagedPath: String,
                                  expectedSHA256: String, relativePath: String) throws {
        let source = try FileHandle(forReadingFrom: URL(fileURLWithPath: sourcePath))
        defer { try? source.close() }

        guard FileManager.default.createFile(atPath: stagedPath, contents: nil,
                                             attributes: [.posixPermissions: 0o644]) else {
            throw VaultError.general("cannot create staged object")
        }
        let destination = try FileHandle(forWritingTo: URL(fileURLWithPath: stagedPath))
        defer { try? destination.close() }

        var hasher = SHA256()
        while true {
            guard let chunk = try source.read(upToCount: 1 << 20) else { break }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            try chunk.writeAll(to: destination)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == expectedSHA256 else {
            throw VaultError.entry(relativePath: relativePath,
                                   reason: "file changed between pre-check and commit")
        }
    }
}

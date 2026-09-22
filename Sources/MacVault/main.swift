import Foundation
import CryptoKit
import SQLite3
import Darwin

// MARK: - Exit codes

private enum ExitCode {
    static let ok: Int32 = 0
    static let runtimeError: Int32 = 1
    static let usageError: Int32 = 64
}

private func failUsage(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(ExitCode.usageError)
}

private func failRuntime(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(ExitCode.runtimeError)
}

// MARK: - Help text

private let helpText = """
macvault — local project materials utility

Usage:
  macvault init --vault <dir>
  macvault import --vault <dir> --source <dir> --json
  macvault list --vault <dir> --json [--name <substring>]
  macvault [--help | --version]

Options:
  -h, --help               Show this help.
      --version            Show the program version.
      --vault <dir>        Vault directory.
      --source <dir>       Source directory to import from.
      --json               Emit machine-readable JSON.
      --name <substring>   Filter entries by file name (case-insensitive).
"""

// MARK: - Argument parsing

private struct Options {
    var vault: String?
    var source: String?
    var json = false
    var name: String?
}

/// Parse options for a subcommand. `valueFlags`/`boolFlags` name exactly the
/// flags the subcommand accepts; anything else (including positional args) is
/// a usage error. Repeating any flag is a conflict.
private func parseOptions(
    _ args: [String],
    valueFlags: Set<String>,
    boolFlags: Set<String>
) -> Options {
    var opts = Options()
    var seen = Set<String>()
    var i = 0
    while i < args.count {
        let arg = args[i]
        if valueFlags.contains(arg) {
            guard i + 1 < args.count else {
                failUsage("option \(arg) requires a value")
            }
            let value = args[i + 1]
            if value.hasPrefix("-") {
                failUsage("option \(arg) requires a value")
            }
            if seen.contains(arg) {
                failUsage("option \(arg) given more than once")
            }
            seen.insert(arg)
            switch arg {
            case "--vault": opts.vault = value
            case "--source": opts.source = value
            case "--name": opts.name = value
            default: break
            }
            i += 2
        } else if boolFlags.contains(arg) {
            if seen.contains(arg) {
                failUsage("option \(arg) given more than once")
            }
            seen.insert(arg)
            if arg == "--json" { opts.json = true }
            i += 1
        } else {
            failUsage("unknown option or argument: \(arg)")
        }
    }
    return opts
}

// MARK: - Filesystem helpers

private enum FS {
    static func isDirectory(_ path: String) -> Bool {
        var st = stat()
        guard stat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR
    }

    static func exists(_ path: String) -> Bool {
        access(path, F_OK) == 0
    }

    static func isReadable(_ path: String) -> Bool {
        access(path, R_OK) == 0
    }

    static func mkdirP(_ path: String) -> Bool {
        (try? FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: true
        )) != nil
    }

    static func removeRecursive(_ path: String) {
        if exists(path) {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    static func namesInDirectory(_ path: String) -> Set<String> {
        let items = try? FileManager.default.contentsOfDirectory(atPath: path)
        return Set(items ?? [])
    }

    /// Recursively enumerate entries beneath `dir`, in deterministic order.
    /// Symlinks and special files are included as well so preflight can
    /// reject them; `relativePath` is POSIX-style relative to `dir`.
    static func walk(_ dir: String) -> [(relativePath: String, absolutePath: String)] {
        var out: [(String, String)] = []
        let baseURL = URL(fileURLWithPath: dir, isDirectory: true)

        func recurse(_ url: URL, prefix: String) {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil
            ) else { return }
            for entry in entries.sorted(by: { $0.path < $1.path }) {
                let name = entry.lastPathComponent
                let rel = prefix.isEmpty ? name : prefix + "/" + name
                var st = stat()
                guard lstat(entry.path, &st) == 0 else {
                    out.append((rel, entry.path))
                    continue
                }
                switch st.st_mode & S_IFMT {
                case S_IFDIR:
                    recurse(entry, prefix: rel)
                default:
                    // Regular files, symlinks and special files: preflight
                    // decides which are acceptable.
                    out.append((rel, entry.path))
                }
            }
        }
        recurse(baseURL, prefix: "")
        return out
    }
}

/// A relative path from the walk must stay inside the source tree.
private func isContainedRelativePath(_ rel: String) -> Bool {
    guard !rel.hasPrefix("/"), !rel.isEmpty else { return false }
    for part in rel.split(separator: "/", omittingEmptySubsequences: false) {
        if part == ".." || part.isEmpty { return false }
    }
    return true
}

// MARK: - Hashing / staging (POSIX, symlink-safe)

private enum FileError: Error {
    case openFailed(String)
    case notRegular
    case ioFailed(String)
}

/// Open `path` for reading without following a trailing symlink, and require
/// the opened descriptor to be a regular file.
private func openRegularReadOnly(_ path: String) throws -> Int32 {
    let fd = open(path, O_RDONLY | O_NOFOLLOW)
    if fd < 0 { throw FileError.openFailed(path) }
    var st = stat()
    if fstat(fd, &st) != 0 || (st.st_mode & S_IFMT) != S_IFREG {
        close(fd)
        throw FileError.notRegular
    }
    return fd
}

private func sha256OfRegularFile(_ path: String) throws -> (hex: String, size: Int64) {
    let fd = try openRegularReadOnly(path)
    defer { close(fd) }
    var hasher = SHA256()
    var total: Int64 = 0
    var buf = [UInt8](repeating: 0, count: 1 << 20)
    while true {
        let n = read(fd, &buf, buf.count)
        if n < 0 {
            if errno == EINTR { continue }
            throw FileError.ioFailed(path)
        }
        if n == 0 { break }
        total += Int64(n)
        hasher.update(data: Data(bytes: &buf, count: n))
    }
    let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    return (hex, total)
}

/// Stream `src` to a freshly created `dst`, returning the SHA-256 and size of
/// exactly the bytes written. Fails unless `src` is a regular non-symlink.
private func stageCopy(src: String, dst: String) throws -> (hex: String, size: Int64) {
    let inFD = try openRegularReadOnly(src)
    defer { close(inFD) }

    let outFD = open(dst, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    if outFD < 0 { throw FileError.openFailed(dst) }
    var failed = false
    defer {
        close(outFD)
        if failed { unlink(dst) }
    }

    var hasher = SHA256()
    var total: Int64 = 0
    var buf = [UInt8](repeating: 0, count: 1 << 20)
    while true {
        let n = read(inFD, &buf, buf.count)
        if n < 0 {
            if errno == EINTR { continue }
            failed = true
            throw FileError.ioFailed(src)
        }
        if n == 0 { break }
        hasher.update(data: Data(bytes: &buf, count: n))
        var written = 0
        while written < n {
            let w = buf.withUnsafeBytes { raw -> Int in
                write(outFD, raw.baseAddress!.advanced(by: written), n - written)
            }
            if w < 0 {
                if errno == EINTR { continue }
                failed = true
                throw FileError.ioFailed(dst)
            }
            written += w
        }
        total += Int64(n)
    }
    let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    return (hex, total)
}

// MARK: - JSON helpers

private enum JSON {
    static func string(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }
}

// MARK: - SQLite catalog

private enum SQLiteError: Error {
    case message(String)
}

private final class Catalog {
    private var db: OpaquePointer?

    init(path: String) throws {
        var handle: OpaquePointer?
        if sqlite3_open(path, &handle) != SQLITE_OK {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let h = handle { sqlite3_close(h) }
            throw SQLiteError.message(msg)
        }
        db = handle
        sqlite3_busy_timeout(handle, 5000)
        try exec("PRAGMA journal_mode=WAL;")
        // IF NOT EXISTS throughout: running init again must never wipe data.
        try exec("""
        CREATE TABLE IF NOT EXISTS catalog_entries (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            relative_path TEXT    NOT NULL UNIQUE,
            sha256        TEXT    NOT NULL,
            size          INTEGER NOT NULL
        );
        """)
        try exec("""
        CREATE INDEX IF NOT EXISTS idx_catalog_path
        ON catalog_entries(relative_path);
        """)
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    fileprivate func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw SQLiteError.message(msg)
        }
    }

    fileprivate func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw SQLiteError.message(String(cString: sqlite3_errmsg(db)))
        }
        return stmt!
    }

    func beginImmediate() throws { try exec("BEGIN IMMEDIATE;") }
    func commit() throws { try exec("COMMIT;") }
    func rollback() { _ = try? exec("ROLLBACK;") }

    func existingEntry(relativePath rel: String) -> (sha256: String, size: Int64)? {
        guard let stmt = try? prepare(
            "SELECT sha256, size FROM catalog_entries WHERE relative_path = ?;"
        ) else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, rel, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        if sqlite3_step(stmt) == SQLITE_ROW {
            let sha = String(cString: sqlite3_column_text(stmt, 0))
            let size = sqlite3_column_int64(stmt, 1)
            return (sha, size)
        }
        return nil
    }

    /// Insert, or update the row when the same relative path already holds
    /// different content. The stable id is preserved.
    func upsertEntry(relativePath rel: String, sha256: String, size: Int64) throws {
        let stmt = try prepare("""
            INSERT INTO catalog_entries (relative_path, sha256, size) VALUES (?, ?, ?)
            ON CONFLICT(relative_path) DO UPDATE SET
                sha256 = excluded.sha256,
                size   = excluded.size;
        """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, rel, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, sha256, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(stmt, 3, size)
        if sqlite3_step(stmt) != SQLITE_DONE {
            throw SQLiteError.message(String(cString: sqlite3_errmsg(db)))
        }
    }

    struct Entry {
        let id: Int64
        let relativePath: String
        let sha256: String
        let size: Int64
    }

    func listEntries(nameFilter: String?) throws -> [Entry] {
        let stmt = try prepare("""
            SELECT id, relative_path, sha256, size FROM catalog_entries
            ORDER BY relative_path ASC, id ASC;
        """)
        defer { sqlite3_finalize(stmt) }
        var rows: [Entry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let path = String(cString: sqlite3_column_text(stmt, 1))
            let sha = String(cString: sqlite3_column_text(stmt, 2))
            let size = sqlite3_column_int64(stmt, 3)
            if let f = nameFilter {
                let fileName = (path as NSString).lastPathComponent
                if fileName.range(of: f, options: .caseInsensitive) == nil {
                    continue
                }
            }
            rows.append(Entry(id: id, relativePath: path, sha256: sha, size: size))
        }
        return rows
    }
}

// MARK: - Vault layout

private struct VaultPaths {
    let root: String
    var catalog: String { root + "/catalog.sqlite3" }
    var objects: String { root + "/objects" }
    var tmp: String { root + "/.import-tmp" }

    func isInitialized() -> Bool {
        FS.exists(catalog) && FS.isDirectory(objects)
    }
}

// MARK: - Commands

private func requireVaultInitialized(_ vp: VaultPaths, vaultArg: String) {
    guard FS.isDirectory(vp.root) else {
        failRuntime("vault directory does not exist: \(vaultArg)")
    }
    guard vp.isInitialized() else {
        failRuntime("vault is not initialized (run 'macvault init --vault \(vaultArg)')")
    }
}

private func cmdInit(_ opts: Options) {
    guard let vault = opts.vault, !vault.isEmpty else {
        failUsage("init requires --vault <dir>")
    }
    if FS.exists(vault) && !FS.isDirectory(vault) {
        failRuntime("vault path is not a directory: \(vault)")
    }
    if !FS.mkdirP(vault) {
        failRuntime("cannot create vault directory: \(vault)")
    }
    if !FS.mkdirP(VaultPaths(root: vault).objects) {
        failRuntime("cannot create objects directory")
    }
    do {
        // Opening creates the schema; close on scope exit. IF NOT EXISTS
        // means re-running init keeps all existing data.
        _ = try Catalog(path: VaultPaths(root: vault).catalog)
    } catch {
        failRuntime("cannot initialize catalog: \(error)")
    }
}

private func cmdImport(_ opts: Options) {
    guard let vault = opts.vault, !vault.isEmpty else {
        failUsage("import requires --vault <dir>")
    }
    guard let source = opts.source, !source.isEmpty else {
        failUsage("import requires --source <dir>")
    }
    guard opts.json else {
        failUsage("import requires --json")
    }

    let vp = VaultPaths(root: vault)
    requireVaultInitialized(vp, vaultArg: vault)
    guard FS.isDirectory(source) else {
        failRuntime("source directory does not exist: \(source)")
    }

    // Fresh staging area (clears leftovers from a crashed previous run).
    FS.removeRecursive(vp.tmp)
    guard mkdir(vp.tmp, 0o755) == 0 else {
        failRuntime("cannot create staging area: \(vp.tmp)")
    }

    // All failure paths during import run through failImport: roll back the
    // transaction, drop anything staged, and remove any new objects already
    // materialized so the vault stays in its pre-import state.
    var catalog: Catalog? = nil
    var transactionOpen = false
    var materializedNewObjects: [String] = []

    func failImport(_ message: String) -> Never {
        if transactionOpen { catalog?.rollback() }
        for path in materializedNewObjects { unlink(path) }
        FS.removeRecursive(vp.tmp)
        failRuntime(message)
    }

    // ---- Preflight: walk + validate every entry -------------------------
    let walked = FS.walk(source)
    var seenPaths = Set<String>()
    for (rel, abs) in walked {
        if !isContainedRelativePath(rel) {
            failImport("path escapes source directory: \(rel)")
        }
        if !seenPaths.insert(rel).inserted {
            failImport("duplicate path in source: \(rel)")
        }
        var st = stat()
        if lstat(abs, &st) != 0 {
            failImport("cannot stat file: \(rel)")
        }
        switch st.st_mode & S_IFMT {
        case S_IFLNK:
            failImport("symbolic link not allowed: \(rel)")
        case S_IFREG:
            break
        default:
            failImport("not a regular file: \(rel)")
        }
        if !FS.isReadable(abs) {
            failImport("file is not readable: \(rel)")
        }
    }

    // ---- Hash all entries (still nothing has been committed) -------------
    var planned: [(rel: String, abs: String, sha: String, size: Int64)] = []
    for (rel, abs) in walked {
        do {
            let h = try sha256OfRegularFile(abs)
            planned.append((rel, abs, h.hex, h.size))
        } catch {
            failImport("cannot read file: \(rel)")
        }
    }

    // Object blobs present before this import decide reuse counting.
    let existingObjects = FS.namesInDirectory(vp.objects)

    do {
        catalog = try Catalog(path: vp.catalog)
    } catch {
        failImport("cannot open catalog: \(error)")
    }

    var imported = 0
    var unchanged = 0
    var reusedObjects = 0

    // Entries that need catalog work.
    var toCommit: [(rel: String, sha: String, size: Int64)] = []
    // New blobs to stage, one per hash that was neither in the store already
    // nor staged earlier in this batch.
    var toStage: [(sha: String, size: Int64, abs: String, tmp: String, final: String, rel: String)] = []
    var knownBlobs = existingObjects

    for entry in planned {
        if let existing = catalog!.existingEntry(relativePath: entry.rel),
           existing.sha256 == entry.sha, existing.size == entry.size {
            unchanged += 1
            continue
        }
        if knownBlobs.contains(entry.sha) {
            // Blob already in the store, or staged for an earlier entry in
            // this batch: content is shared, no second copy.
            reusedObjects += 1
        } else {
            knownBlobs.insert(entry.sha)
            toStage.append((
                entry.sha, entry.size, entry.abs,
                vp.tmp + "/" + entry.sha, vp.objects + "/" + entry.sha, entry.rel
            ))
        }
        toCommit.append((entry.rel, entry.sha, entry.size))
        imported += 1
    }

    // ---- Stage bytes into the temp area and verify digests ---------------
    for s in toStage {
        do {
            let h = try stageCopy(src: s.abs, dst: s.tmp)
            if h.hex != s.sha || h.size != s.size {
                failImport("staged file digest mismatch: \(s.rel)")
            }
        } catch {
            failImport("cannot stage file: \(s.rel)")
        }
    }

    // ---- Transaction: catalog rows, then atomic renames, then COMMIT ------
    do {
        try catalog!.beginImmediate()
        transactionOpen = true
    } catch {
        failImport("cannot begin transaction: \(error)")
    }

    for c in toCommit {
        do {
            try catalog!.upsertEntry(relativePath: c.rel, sha256: c.sha, size: c.size)
        } catch {
            failImport("cannot write catalog entry: \(c.rel)")
        }
    }

    for s in toStage {
        if rename(s.tmp, s.final) != 0 {
            failImport("cannot store object for file: \(s.rel)")
        }
        materializedNewObjects.append(s.final)
    }

    do {
        try catalog!.commit()
        transactionOpen = false
    } catch {
        failImport("commit failed")
    }

    FS.removeRecursive(vp.tmp)

    print("{\"imported\":\(imported),\"unchanged\":\(unchanged),\"reusedObjects\":\(reusedObjects)}")
}

private func cmdList(_ opts: Options) {
    guard let vault = opts.vault, !vault.isEmpty else {
        failUsage("list requires --vault <dir>")
    }
    guard opts.json else {
        failUsage("list requires --json")
    }

    let vp = VaultPaths(root: vault)
    requireVaultInitialized(vp, vaultArg: vault)

    let catalog: Catalog
    do {
        catalog = try Catalog(path: vp.catalog)
    } catch {
        failRuntime("cannot open catalog: \(error)")
    }

    let entries: [Catalog.Entry]
    do {
        entries = try catalog.listEntries(nameFilter: opts.name)
    } catch {
        failRuntime("cannot list entries: \(error)")
    }

    let lines = entries.map { e -> String in
        "{\"id\":\(e.id),\"relativePath\":\(JSON.string(e.relativePath))," +
        "\"sha256\":\"\(e.sha256)\",\"size\":\(e.size)}"
    }
    print("[" + lines.joined(separator: ",") + "]")
}

// MARK: - Entry point

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.isEmpty {
    print(helpText)
    exit(ExitCode.ok)
}

let command = arguments[0]
let rest = Array(arguments.dropFirst())

switch command {
case "-h", "--help":
    if !rest.isEmpty { failUsage("\(command) takes no arguments") }
    print(helpText)
case "--version":
    if !rest.isEmpty { failUsage("--version takes no arguments") }
    print("macvault 0.1.0")
case "init":
    if rest.contains(where: { $0 == "-h" || $0 == "--help" }) && rest.count == 1 {
        print(helpText)
        exit(ExitCode.ok)
    }
    cmdInit(parseOptions(
        rest,
        valueFlags: ["--vault"],
        boolFlags: []
    ))
case "import":
    if rest.contains(where: { $0 == "-h" || $0 == "--help" }) && rest.count == 1 {
        print(helpText)
        exit(ExitCode.ok)
    }
    cmdImport(parseOptions(
        rest,
        valueFlags: ["--vault", "--source"],
        boolFlags: ["--json"]
    ))
case "list":
    if rest.contains(where: { $0 == "-h" || $0 == "--help" }) && rest.count == 1 {
        print(helpText)
        exit(ExitCode.ok)
    }
    cmdList(parseOptions(
        rest,
        valueFlags: ["--vault", "--name"],
        boolFlags: ["--json"]
    ))
default:
    failUsage("unknown command: \(command)")
}

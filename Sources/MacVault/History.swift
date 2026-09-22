import CryptoKit
import Darwin
import Foundation

// MARK: - History record model
//
// A history rooted at ROOT consists of a marker file `history.json` (exactly
// the structure {"version":1}) and one JSON record per project/version pair
// under `records/`. Record file names are the SHA-256 of the key's UTF-8
// bytes, so arbitrary project/version segments stay filesystem-safe and
// concurrent publishes to the same key target the same path.

struct HistoryRecord {
    let project: String
    let version: String
    let snapshotPath: String
    let snapshotSha256: String
    let files: [FileRecord]
}

private enum HistoryError: Error {
    case corrupt(String)   // exit 65
    case io(String)        // exit 74
}

private let markerName = "history.json"
private let recordsDirName = "records"
private let markerContent = "{\"version\":1}"

private func sha256Hex(of data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func recordFileName(project: String, version: String) -> String {
    var hasher = SHA256()
    hasher.update(data: Data(project.utf8))
    hasher.update(data: Data([0]))
    hasher.update(data: Data(version.utf8))
    return hasher.finalize().map { String(format: "%02x", $0) }.joined() + ".json"
}

// MARK: - Record rendering

private func renderFiles(_ files: [FileRecord]) -> String {
    "[" + files.map { record in
        "{\"path\":\(jsonEscape(record.path)),"
            + "\"sha256\":\(jsonEscape(record.sha256)),"
            + "\"size\":\(record.size)}"
    }.joined(separator: ",") + "]"
}

private func renderRecord(_ record: HistoryRecord) -> String {
    "{\"project\":\(jsonEscape(record.project)),"
        + "\"version\":\(jsonEscape(record.version)),"
        + "\"snapshotPath\":\(jsonEscape(record.snapshotPath)),"
        + "\"snapshotSha256\":\(jsonEscape(record.snapshotSha256)),"
        + "\"files\":\(renderFiles(record.files))}"
}

private func renderQueryEntry(_ record: HistoryRecord, status: String) -> String {
    "{\"project\":\(jsonEscape(record.project)),"
        + "\"version\":\(jsonEscape(record.version)),"
        + "\"snapshotPath\":\(jsonEscape(record.snapshotPath)),"
        + "\"snapshotSha256\":\(jsonEscape(record.snapshotSha256)),"
        + "\"snapshotStatus\":\(jsonEscape(status)),"
        + "\"files\":\(renderFiles(record.files))}"
}

// MARK: - Filesystem helpers

private func reportHistoryError(_ error: HistoryError) -> Int32 {
    switch error {
    case .corrupt(let message):
        writeStderr("error: \(message)\n")
        return 65
    case .io(let message):
        writeStderr("error: \(message)\n")
        return 74
    }
}

private func listDirectory(_ path: String) throws -> [String] {
    do {
        return try FileManager.default.contentsOfDirectory(atPath: path)
    } catch {
        throw HistoryError.io("cannot list \(path): \(error.localizedDescription)")
    }
}

/// The marker must be exactly the structure {"version":1}.
private func validateMarker(root: String) throws {
    let markerPath = (root as NSString).appendingPathComponent(markerName)
    let data: Data
    do {
        data = try Data(contentsOf: URL(fileURLWithPath: markerPath))
    } catch {
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: markerPath, isDirectory: &isDirectory) {
            throw HistoryError.corrupt("missing history marker: \(markerPath)")
        }
        throw HistoryError.io(
            "cannot read history marker: \(error.localizedDescription)")
    }
    do {
        try decodeHistoryMarker(data)
    } catch let error as SnapshotDecodeError {
        throw HistoryError.corrupt("invalid history marker: \(error.message)")
    }
}

private enum PublishResult {
    case published
    case alreadyExists
}

/// Writes `bytes` to a staging file inside `stagingDir` and publishes it with
/// `link(2)`, which fails with EEXIST instead of ever overwriting an existing
/// destination — so concurrent publishers of the same key let exactly one
/// value win. The staging file is removed on every failure path.
private func stageAndPublish(
    bytes: Data, to finalPath: String, stagingDir: String, prefix: String
) throws -> PublishResult {
    let tempName = String(
        format: "%@%d.%016llx.tmp",
        prefix,
        ProcessInfo.processInfo.processIdentifier,
        UInt64.random(in: 0...UInt64.max))
    let tempPath = (stagingDir as NSString).appendingPathComponent(tempName)

    let fd = open(tempPath, O_CREAT | O_EXCL | O_WRONLY, 0o644)
    guard fd >= 0 else {
        throw HistoryError.io(
            "cannot create staging file: \(String(cString: strerror(errno)))")
    }

    do {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { rawBuffer -> Int in
                write(fd, rawBuffer.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if written < 0 {
                if errno == EINTR { continue }
                throw HistoryError.io(
                    "staging write failed: \(String(cString: strerror(errno)))")
            }
            offset += written
        }
        if fsync(fd) != 0 {
            throw HistoryError.io(
                "staging sync failed: \(String(cString: strerror(errno)))")
        }
        if close(fd) != 0 {
            throw HistoryError.io(
                "staging close failed: \(String(cString: strerror(errno)))")
        }
    } catch {
        close(fd)
        unlink(tempPath)
        throw error
    }

    if link(tempPath, finalPath) != 0 {
        let linkError = errno
        unlink(tempPath)
        if linkError == EEXIST { return .alreadyExists }
        throw HistoryError.io(
            "cannot publish \(finalPath): \(String(cString: strerror(linkError)))")
    }
    unlink(tempPath)
    return .published
}

private func ensureRecordsDir(root: String) throws {
    let recordsDir = (root as NSString).appendingPathComponent(recordsDirName)
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: recordsDir, isDirectory: &isDirectory) {
        guard isDirectory.boolValue else {
            throw HistoryError.corrupt("records path is not a directory: \(recordsDir)")
        }
        return
    }
    do {
        try FileManager.default.createDirectory(
            atPath: recordsDir, withIntermediateDirectories: false)
    } catch {
        // A concurrent initializer may have created it first.
        var nowDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: recordsDir, isDirectory: &nowDirectory),
              nowDirectory.boolValue
        else {
            throw HistoryError.io(
                "cannot create records directory: \(error.localizedDescription)")
        }
    }
}

/// Initializes an empty or freshly created ROOT: publishes the marker and
/// creates the records directory. Concurrent initializers converge because
/// the marker publish is atomic and idempotent.
private func initializeRoot(_ root: String) throws {
    let markerPath = (root as NSString).appendingPathComponent(markerName)
    let result = try stageAndPublish(
        bytes: Data(markerContent.utf8),
        to: markerPath,
        stagingDir: root,
        prefix: ".macvault-history.")
    if result == .alreadyExists {
        try validateMarker(root: root)
    }
    try ensureRecordsDir(root: root)
}

/// Brings ROOT into the initialized state for `history-add`: creates a
/// missing ROOT, initializes an empty one, and requires the marker on a
/// non-empty one.
private func prepareRootForAdd(root: String) throws {
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory) {
        // The not-a-directory case is rejected by the caller with 64.
        let entries = try listDirectory(root)
        if entries.isEmpty {
            try initializeRoot(root)
        } else {
            try validateMarker(root: root)
            try ensureRecordsDir(root: root)
        }
    } else {
        do {
            try FileManager.default.createDirectory(
                atPath: root, withIntermediateDirectories: true)
        } catch {
            throw HistoryError.io(
                "cannot create history root \(root): \(error.localizedDescription)")
        }
        try initializeRoot(root)
    }
}

/// Loads one record file, or nil when it does not exist. An undecodable
/// record makes the whole ROOT corrupt.
private func loadRecord(at path: String) throws -> HistoryRecord? {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
        return nil
    }
    let data: Data
    do {
        data = try Data(contentsOf: URL(fileURLWithPath: path))
    } catch {
        throw HistoryError.io(
            "cannot read record \(path): \(error.localizedDescription)")
    }
    do {
        return try decodeHistoryRecord(data)
    } catch let error as SnapshotDecodeError {
        throw HistoryError.corrupt("invalid record \(path): \(error.message)")
    }
}

private func loadAllRecords(root: String) throws -> [HistoryRecord] {
    let recordsDir = (root as NSString).appendingPathComponent(recordsDirName)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: recordsDir, isDirectory: &isDirectory) else {
        return []
    }
    guard isDirectory.boolValue else {
        throw HistoryError.corrupt("records path is not a directory: \(recordsDir)")
    }
    var records: [HistoryRecord] = []
    for name in try listDirectory(recordsDir).sorted(by: utf8Precedes)
    where name.hasSuffix(".json") {
        let path = (recordsDir as NSString).appendingPathComponent(name)
        if let record = try loadRecord(at: path) {
            records.append(record)
        }
    }
    return records
}

/// Same registered value means the same snapshot absolute path and the same
/// snapshot byte hash, compared as raw UTF-8 bytes.
private func sameRegisteredValue(_ a: HistoryRecord, _ b: HistoryRecord) -> Bool {
    utf8Identical(a.snapshotPath, b.snapshotPath)
        && utf8Identical(a.snapshotSha256, b.snapshotSha256)
}

// MARK: - `history-add`

func runHistoryAdd(root: String, project: String, version: String, snapshotPath: String) -> Int32 {
    guard isValidHistorySegment(project), isValidHistorySegment(version) else {
        writeStderr("error: P and V must be single path segments valid in snapshot paths\n")
        return 64
    }

    var rootIsDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: root, isDirectory: &rootIsDirectory),
       !rootIsDirectory.boolValue {
        writeStderr("error: not a directory: \(root)\n")
        return 64
    }

    // Strictly decode the snapshot before touching ROOT, so a failed add
    // leaves no trace behind.
    let snapshotData: Data
    do {
        snapshotData = try Data(contentsOf: URL(fileURLWithPath: snapshotPath))
    } catch {
        writeStderr("error: cannot read snapshot \(snapshotPath): \(error.localizedDescription)\n")
        return 65
    }
    let files: [FileRecord]
    do {
        files = try decodeSnapshot(snapshotData)
    } catch let error as SnapshotDecodeError {
        writeStderr("error: invalid snapshot \(snapshotPath): \(error.message)\n")
        return 65
    } catch {
        writeStderr("error: invalid snapshot \(snapshotPath)\n")
        return 65
    }

    let record = HistoryRecord(
        project: project,
        version: version,
        snapshotPath: normalizedRoot(snapshotPath),
        snapshotSha256: sha256Hex(of: snapshotData),
        files: files)

    do {
        try prepareRootForAdd(root: root)
    } catch let error as HistoryError {
        return reportHistoryError(error)
    } catch {
        writeStderr("error: \(error.localizedDescription)\n")
        return 74
    }

    let recordsDir = (root as NSString).appendingPathComponent(recordsDirName)
    let finalPath = (recordsDir as NSString).appendingPathComponent(
        recordFileName(project: project, version: version))

    func checkExisting(_ existing: HistoryRecord) -> Int32 {
        if sameRegisteredValue(existing, record) {
            return 0
        }
        writeStderr(
            "error: a different record is already registered for"
                + " project \(project) version \(version)\n")
        return 73
    }

    do {
        if let existing = try loadRecord(at: finalPath) {
            guard utf8Identical(existing.project, project),
                  utf8Identical(existing.version, version)
            else {
                throw HistoryError.corrupt("record key mismatch: \(finalPath)")
            }
            return checkExisting(existing)
        }
        let result = try stageAndPublish(
            bytes: Data(renderRecord(record).utf8),
            to: finalPath,
            stagingDir: recordsDir,
            prefix: ".macvault-record.")
        if result == .published {
            return 0
        }
        // Lost a concurrent publish race; the winning record decides whether
        // this add is idempotently satisfied or in conflict.
        guard let winner = try loadRecord(at: finalPath) else {
            throw HistoryError.io("record vanished after publish race: \(finalPath)")
        }
        return checkExisting(winner)
    } catch let error as HistoryError {
        return reportHistoryError(error)
    } catch {
        writeStderr("error: \(error.localizedDescription)\n")
        return 74
    }
}

// MARK: - `history-query`

func runHistoryQuery(
    root: String, project: String?, version: String?, path: String?
) -> Int32 {
    if let project, !isValidHistorySegment(project) {
        writeStderr("error: P must be a single path segment valid in snapshot paths\n")
        return 64
    }
    if let version, !isValidHistorySegment(version) {
        writeStderr("error: V must be a single path segment valid in snapshot paths\n")
        return 64
    }
    if let path, !isValidRelativePath(path) {
        writeStderr("error: PATH must be a valid snapshot relative path\n")
        return 64
    }

    var rootIsDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root, isDirectory: &rootIsDirectory) else {
        print("[]")
        return 0
    }
    guard rootIsDirectory.boolValue else {
        writeStderr("error: not a directory: \(root)\n")
        return 64
    }

    do {
        if try listDirectory(root).isEmpty {
            print("[]")
            return 0
        }
        try validateMarker(root: root)

        var records = try loadAllRecords(root: root)
        records = records.filter { record in
            if let project, !utf8Identical(record.project, project) { return false }
            if let version, !utf8Identical(record.version, version) { return false }
            if let path, !record.files.contains(where: { utf8Identical($0.path, path) }) {
                return false
            }
            return true
        }
        records.sort { a, b in
            utf8Identical(a.project, b.project)
                ? utf8Precedes(a.version, b.version)
                : utf8Precedes(a.project, b.project)
        }

        var items: [String] = []
        for record in records {
            items.append(renderQueryEntry(record, status: try snapshotStatus(of: record)))
        }
        print("[" + items.joined(separator: ",") + "]")
        return 0
    } catch let error as HistoryError {
        return reportHistoryError(error)
    } catch {
        writeStderr("error: \(error.localizedDescription)\n")
        return 74
    }
}

/// Re-hashes the registered snapshot file: identical bytes are `intact`,
/// different bytes are `modified`, and a vanished file is `missing`.
private func snapshotStatus(of record: HistoryRecord) throws -> String {
    guard FileManager.default.fileExists(atPath: record.snapshotPath) else {
        return "missing"
    }
    let data: Data
    do {
        data = try Data(contentsOf: URL(fileURLWithPath: record.snapshotPath))
    } catch {
        throw HistoryError.io(
            "cannot read snapshot \(record.snapshotPath): \(error.localizedDescription)")
    }
    return sha256Hex(of: data) == record.snapshotSha256 ? "intact" : "modified"
}

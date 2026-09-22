import CryptoKit
import Foundation

// MARK: - History store errors

private enum HistoryError: Error {
    case corrupt(String) // exit 65
    case io(String)      // exit 74
}

// MARK: - History record model

struct HistoryRecord {
    let project: String
    let version: String
    let snapshotPath: String
    let snapshotSha256: String
    let files: [FileRecord]
}

private let historyMarkerName = "history.json"
private let historyMarkerJSON = "{\"version\":1}"
private let recordsDirectoryName = "records"

// MARK: - Helpers

/// P and V must be single path segments that the snapshot relative-path
/// rules allow: non-empty, no `/`, not `.`/`..`, no NUL bytes.
private func isValidHistorySegment(_ value: String) -> Bool {
    !value.contains("/") && isValidRelativePath(value)
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Record files live at `records/<H(P)>/<H(V)>.json` where H is the SHA-256
/// of the segment's UTF-8 bytes, so any valid segment maps to a fixed-length,
/// filesystem-safe name and the raw bytes are never interpreted by the file
/// system (no Unicode normalization, no reserved names).
private func historyKeyHash(_ segment: String) -> String {
    sha256Hex(Data(segment.utf8))
}

private func removeIfEmptyDirectory(_ path: String) {
    rmdir(path)
}

// MARK: - Marker and root handling

private func isValidHistoryMarker(_ data: Data) -> Bool {
    guard let text = String(data: data, encoding: .utf8),
          let value = try? JSONParser.parse(text),
          case .object(let members) = value,
          members.count == 1,
          members[0].key == "version",
          case .number(let versionLexeme) = members[0].value,
          versionLexeme == "1"
    else {
        return false
    }
    return true
}

private func validateHistoryMarker(_ root: String) throws {
    let markerPath = (root as NSString).appendingPathComponent(historyMarkerName)
    let data: Data
    do {
        data = try Data(contentsOf: URL(fileURLWithPath: markerPath))
    } catch {
        if FileManager.default.fileExists(atPath: markerPath) {
            throw HistoryError.io(
                "cannot read history marker \(markerPath): \(error.localizedDescription)")
        }
        throw HistoryError.corrupt("missing history marker: \(markerPath)")
    }
    guard isValidHistoryMarker(data) else {
        throw HistoryError.corrupt("invalid history marker: \(markerPath)")
    }
}

private enum HistoryRootContents {
    case empty
    case ready
}

/// Inspects an existing history root directory: an empty root may be
/// initialized; a non-empty root must carry a valid marker. Staging files of
/// an in-flight marker publish (`.macvault-snapshot.*.tmp`) do not count as
/// content — a concurrent initializer creates them before the marker itself
/// is linked, and they are removed again on every publish path.
private func inspectHistoryRoot(_ root: String) throws -> HistoryRootContents {
    let entries: [String]
    do {
        entries = try FileManager.default.contentsOfDirectory(atPath: root)
    } catch {
        throw HistoryError.io(
            "cannot list history root \(root): \(error.localizedDescription)")
    }
    let significant = entries.filter {
        !($0.hasPrefix(".macvault-snapshot.") && $0.hasSuffix(".tmp"))
    }
    if significant.isEmpty { return .empty }
    try validateHistoryMarker(root)
    return .ready
}

/// Creates the root directory if missing and publishes the marker if the
/// root is empty. Concurrent initializers race on the marker's `link(2)`
/// publish; the loser validates whatever the winner published.
private func ensureHistoryRoot(_ root: String) throws {
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    if !fileManager.fileExists(atPath: root, isDirectory: &isDirectory) {
        do {
            try fileManager.createDirectory(atPath: root, withIntermediateDirectories: true)
        } catch {
            throw HistoryError.io(
                "cannot create history root \(root): \(error.localizedDescription)")
        }
    } else if !isDirectory.boolValue {
        // The caller checks this up front; only a race can land here.
        throw HistoryError.io("not a directory: \(root)")
    }

    switch try inspectHistoryRoot(root) {
    case .ready:
        return
    case .empty:
        let markerPath = (root as NSString).appendingPathComponent(historyMarkerName)
        do {
            try publishSnapshot(json: historyMarkerJSON, to: markerPath)
        } catch PublishError.destinationExists {
            try validateHistoryMarker(root)
        } catch PublishError.io(let message) {
            throw HistoryError.io(message)
        }
    }
}

// MARK: - Record decoding and rendering

private func decodeHistoryRecord(_ data: Data) throws -> HistoryRecord {
    guard let text = String(data: data, encoding: .utf8) else {
        throw SnapshotDecodeError(message: "history record is not valid UTF-8")
    }
    let value = try JSONParser.parse(text)
    guard case .object(let members) = value else {
        throw SnapshotDecodeError(message: "history record root must be an object")
    }
    let keys = Set(members.map { $0.key })
    guard members.count == 5,
          keys == ["project", "version", "snapshotPath", "snapshotSha256", "files"]
    else {
        throw SnapshotDecodeError(message: "history record has missing or extra fields")
    }
    let fields = Dictionary(uniqueKeysWithValues: members.map { ($0.key, $0.value) })

    guard case .string(let project) = fields["project"], isValidHistorySegment(project) else {
        throw SnapshotDecodeError(message: "history record has an invalid project")
    }
    guard case .string(let version) = fields["version"], isValidHistorySegment(version) else {
        throw SnapshotDecodeError(message: "history record has an invalid version")
    }
    guard case .string(let snapshotPath) = fields["snapshotPath"],
          snapshotPath.hasPrefix("/")
    else {
        throw SnapshotDecodeError(message: "history record has an invalid snapshotPath")
    }
    guard case .string(let snapshotSha256) = fields["snapshotSha256"],
          isValidSha256(snapshotSha256)
    else {
        throw SnapshotDecodeError(message: "history record has an invalid snapshotSha256")
    }
    return HistoryRecord(
        project: project,
        version: version,
        snapshotPath: snapshotPath,
        snapshotSha256: snapshotSha256,
        files: try decodeFiles(fields["files"]!))
}

private func renderHistoryFiles(_ files: [FileRecord]) -> String {
    "[" + files.map { record in
        "{\"path\":\(jsonEscape(record.path)),"
            + "\"sha256\":\(jsonEscape(record.sha256)),"
            + "\"size\":\(record.size)}"
    }.joined(separator: ",") + "]"
}

private func renderHistoryRecord(_ record: HistoryRecord) -> String {
    "{\"project\":\(jsonEscape(record.project)),"
        + "\"version\":\(jsonEscape(record.version)),"
        + "\"snapshotPath\":\(jsonEscape(record.snapshotPath)),"
        + "\"snapshotSha256\":\(jsonEscape(record.snapshotSha256)),"
        + "\"files\":\(renderHistoryFiles(record.files))}"
}

private func renderHistoryItem(_ record: HistoryRecord, status: String) -> String {
    "{\"project\":\(jsonEscape(record.project)),"
        + "\"version\":\(jsonEscape(record.version)),"
        + "\"snapshotPath\":\(jsonEscape(record.snapshotPath)),"
        + "\"snapshotSha256\":\(jsonEscape(record.snapshotSha256)),"
        + "\"snapshotStatus\":\(jsonEscape(status)),"
        + "\"files\":\(renderHistoryFiles(record.files))}"
}

/// Hashes the registered snapshot file: identical bytes are `intact`,
/// different bytes are `modified`, and a vanished file is `missing`.
private func snapshotStatus(snapshotPath: String, expectedSha256: String) throws -> String {
    let data: Data
    do {
        data = try Data(contentsOf: URL(fileURLWithPath: snapshotPath))
    } catch {
        if !FileManager.default.fileExists(atPath: snapshotPath) {
            return "missing"
        }
        throw HistoryError.io(
            "cannot read snapshot \(snapshotPath): \(error.localizedDescription)")
    }
    return sha256Hex(data) == expectedSha256 ? "intact" : "modified"
}

// MARK: - `history-add`

func runHistoryAdd(rootPath: String, project: String, version: String, snapshotPath: String) -> Int32 {
    guard isValidHistorySegment(project) else {
        writeStderr("error: invalid project segment: \(project)\n")
        return 64
    }
    guard isValidHistorySegment(version) else {
        writeStderr("error: invalid version segment: \(version)\n")
        return 64
    }

    let fileManager = FileManager.default
    var rootIsDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: rootPath, isDirectory: &rootIsDirectory),
       !rootIsDirectory.boolValue {
        writeStderr("error: not an existing directory: \(rootPath)\n")
        return 64
    }

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
        snapshotSha256: sha256Hex(snapshotData),
        files: files)

    do {
        try ensureHistoryRoot(rootPath)
    } catch HistoryError.corrupt(let message) {
        writeStderr("error: \(message)\n")
        return 65
    } catch HistoryError.io(let message) {
        writeStderr("error: \(message)\n")
        return 74
    } catch {
        writeStderr("error: \(error)\n")
        return 74
    }

    let recordsDirectory = (rootPath as NSString).appendingPathComponent(recordsDirectoryName)
    let projectDirectory = (recordsDirectory as NSString)
        .appendingPathComponent(historyKeyHash(project))
    do {
        try fileManager.createDirectory(atPath: projectDirectory, withIntermediateDirectories: true)
    } catch {
        writeStderr("error: cannot create history directory: \(error.localizedDescription)\n")
        return 74
    }
    let recordPath = (projectDirectory as NSString)
        .appendingPathComponent(historyKeyHash(version) + ".json")

    // Stage the record inside the store and publish it with link(2): a
    // concurrent registration of the same key loses with EEXIST and leaves
    // no record of its own behind.
    do {
        try publishSnapshot(json: renderHistoryRecord(record), to: recordPath)
        return 0
    } catch PublishError.destinationExists {
        // Handled by the idempotency check below.
    } catch PublishError.io(let message) {
        writeStderr("error: \(message)\n")
        removeIfEmptyDirectory(projectDirectory)
        removeIfEmptyDirectory(recordsDirectory)
        return 74
    } catch {
        writeStderr("error: \(error)\n")
        removeIfEmptyDirectory(projectDirectory)
        removeIfEmptyDirectory(recordsDirectory)
        return 74
    }

    // The key is already registered: an identical registration is an
    // idempotent success, anything else conflicts.
    let existingData: Data
    do {
        existingData = try Data(contentsOf: URL(fileURLWithPath: recordPath))
    } catch {
        writeStderr("error: cannot read history record \(recordPath): \(error.localizedDescription)\n")
        return 74
    }
    let existing: HistoryRecord
    do {
        existing = try decodeHistoryRecord(existingData)
    } catch let error as SnapshotDecodeError {
        writeStderr("error: invalid history record \(recordPath): \(error.message)\n")
        return 65
    } catch {
        writeStderr("error: invalid history record \(recordPath)\n")
        return 65
    }
    guard utf8Identical(existing.project, record.project),
          utf8Identical(existing.version, record.version),
          utf8Identical(existing.snapshotPath, record.snapshotPath),
          existing.snapshotSha256 == record.snapshotSha256
    else {
        writeStderr("error: \(project)/\(version) is already registered with a different snapshot\n")
        return 73
    }
    return 0
}

// MARK: - `history-query`

func runHistoryQuery(rootPath: String, project: String?, version: String?, path: String?) -> Int32 {
    if let project, !isValidHistorySegment(project) {
        writeStderr("error: invalid project segment: \(project)\n")
        return 64
    }
    if let version, !isValidHistorySegment(version) {
        writeStderr("error: invalid version segment: \(version)\n")
        return 64
    }
    if let path, !isValidRelativePath(path) {
        writeStderr("error: invalid path filter: \(path)\n")
        return 64
    }

    let fileManager = FileManager.default
    var rootIsDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: rootPath, isDirectory: &rootIsDirectory) else {
        // A missing root is an empty store; query never creates anything.
        print("[]")
        return 0
    }
    guard rootIsDirectory.boolValue else {
        writeStderr("error: not an existing directory: \(rootPath)\n")
        return 64
    }

    do {
        switch try inspectHistoryRoot(rootPath) {
        case .empty:
            print("[]")
            return 0
        case .ready:
            break
        }
    } catch HistoryError.corrupt(let message) {
        writeStderr("error: \(message)\n")
        return 65
    } catch HistoryError.io(let message) {
        writeStderr("error: \(message)\n")
        return 74
    } catch {
        writeStderr("error: \(error)\n")
        return 74
    }

    let recordsDirectory = (normalizedRoot(rootPath) as NSString)
        .appendingPathComponent(recordsDirectoryName)
    var records: [HistoryRecord] = []
    var recordsIsDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: recordsDirectory, isDirectory: &recordsIsDirectory) {
        guard recordsIsDirectory.boolValue else {
            writeStderr("error: corrupt history store: \(recordsDirectory) is not a directory\n")
            return 65
        }
        var errors: [CompareError] = []
        let recordFiles = enumerateRegularFiles(root: recordsDirectory, errors: &errors)
        guard errors.isEmpty else {
            for error in errors {
                writeStderr("error: \(error.path): \(error.message)\n")
            }
            return 74
        }
        for relative in recordFiles.sorted(by: utf8Precedes) {
            let fullPath = (recordsDirectory as NSString).appendingPathComponent(relative)
            let data: Data
            do {
                data = try Data(contentsOf: URL(fileURLWithPath: fullPath))
            } catch {
                writeStderr("error: cannot read history record \(fullPath): \(error.localizedDescription)\n")
                return 74
            }
            do {
                records.append(try decodeHistoryRecord(data))
            } catch let error as SnapshotDecodeError {
                writeStderr("error: invalid history record \(fullPath): \(error.message)\n")
                return 65
            } catch {
                writeStderr("error: invalid history record \(fullPath)\n")
                return 65
            }
        }
    }

    if let project {
        records = records.filter { utf8Identical($0.project, project) }
    }
    if let version {
        records = records.filter { utf8Identical($0.version, version) }
    }
    if let path {
        records = records.filter { record in
            record.files.contains { utf8Identical($0.path, path) }
        }
    }

    records.sort { a, b in
        utf8Identical(a.project, b.project)
            ? utf8Precedes(a.version, b.version)
            : utf8Precedes(a.project, b.project)
    }

    var items: [String] = []
    for record in records {
        let status: String
        do {
            status = try snapshotStatus(
                snapshotPath: record.snapshotPath,
                expectedSha256: record.snapshotSha256)
        } catch HistoryError.io(let message) {
            writeStderr("error: \(message)\n")
            return 74
        } catch {
            writeStderr("error: \(error)\n")
            return 74
        }
        items.append(renderHistoryItem(record, status: status))
    }
    print("[" + items.joined(separator: ",") + "]")
    return 0
}

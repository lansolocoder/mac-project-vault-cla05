import CryptoKit
import Foundation

struct FileRecord {
    let path: String
    let sha256: String
    let size: Int64
}

struct CompareError: Error {
    let path: String
    let message: String
}

struct DiffEntry {
    let kind: String
    let oldPath: String?
    let newPath: String?
    let oldSha256: String?
    let newSha256: String?
    let oldSize: Int64?
    let newSize: Int64?
}

func utf8Precedes(_ a: String, _ b: String) -> Bool {
    a.utf8.lexicographicallyPrecedes(b.utf8)
}

func writeStderr(_ text: String) {
    FileHandle.standardError.write(Data(text.utf8))
}

func normalizedRoot(_ path: String) -> String {
    if let resolved = realpath(path, nil) {
        defer { free(resolved) }
        return String(cString: resolved)
    }
    var fallback = URL(fileURLWithPath: path).standardizedFileURL.path
    while fallback.count > 1, fallback.hasSuffix("/") {
        fallback.removeLast()
    }
    return fallback
}

private func relativePath(of url: URL, root: String) -> String {
    let path = url.path
    let prefix = root == "/" ? "/" : root + "/"
    if path.hasPrefix(prefix) {
        return String(path.dropFirst(prefix.count))
    }
    return path
}

/// Recursively lists regular files below `root` without following symbolic
/// links. Enumeration problems are appended to `errors`.
func enumerateRegularFiles(root: String, errors: inout [CompareError]) -> [String] {
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
    let rootURL = URL(fileURLWithPath: root)
    var enumerationErrors: [CompareError] = []
    guard let enumerator = FileManager.default.enumerator(
        at: rootURL,
        includingPropertiesForKeys: Array(keys),
        options: [],
        errorHandler: { url, error in
            enumerationErrors.append(CompareError(
                path: relativePath(of: url, root: root),
                message: error.localizedDescription))
            return true
        }
    ) else {
        errors.append(CompareError(path: ".", message: "cannot open directory"))
        return []
    }

    var files: [String] = []
    for case let url as URL in enumerator {
        let relative = relativePath(of: url, root: root)
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: keys)
        } catch {
            errors.append(CompareError(path: relative, message: error.localizedDescription))
            continue
        }
        if values.isSymbolicLink == true {
            // Directory enumeration does not follow symbolic links, so a
            // symlink is simply not a regular file and is skipped here.
            continue
        }
        if values.isRegularFile == true {
            files.append(relative)
        }
    }
    errors.append(contentsOf: enumerationErrors)
    return files
}

private func isRegularFile(_ status: stat) -> Bool {
    status.st_mode & S_IFMT == S_IFREG
}

private func sameModificationTime(_ a: stat, _ b: stat) -> Bool {
    a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec
        && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
}

/// Hashes one regular file, verifying it stays a regular file with unchanged
/// size and modification time across the read.
func hashFile(root: String, relativePath: String) -> Result<FileRecord, CompareError> {
    let fullPath = root == "/" ? "/" + relativePath : root + "/" + relativePath

    var before = stat()
    guard lstat(fullPath, &before) == 0 else {
        return .failure(CompareError(
            path: relativePath,
            message: "cannot stat: \(String(cString: strerror(errno)))"))
    }
    guard isRegularFile(before) else {
        return .failure(CompareError(path: relativePath, message: "not a regular file"))
    }
    guard let handle = FileHandle(forReadingAtPath: fullPath) else {
        return .failure(CompareError(path: relativePath, message: "cannot open for reading"))
    }
    defer { try? handle.close() }

    var hasher = SHA256()
    while true {
        let chunk: Data
        do {
            chunk = try handle.read(upToCount: 1 << 20) ?? Data()
        } catch {
            return .failure(CompareError(
                path: relativePath,
                message: "read failed: \(error.localizedDescription)"))
        }
        if chunk.isEmpty { break }
        hasher.update(data: chunk)
    }

    var after = stat()
    guard lstat(fullPath, &after) == 0 else {
        return .failure(CompareError(path: relativePath, message: "vanished while reading"))
    }
    guard isRegularFile(after),
          after.st_size == before.st_size,
          sameModificationTime(after, before)
    else {
        return .failure(CompareError(path: relativePath, message: "changed while reading"))
    }

    let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    return .success(FileRecord(path: relativePath, sha256: hex, size: before.st_size))
}

func computeDiff(oldRecords: [FileRecord], newRecords: [FileRecord]) -> [DiffEntry] {
    let newByPath = Dictionary(uniqueKeysWithValues: newRecords.map { ($0.path, $0) })
    let oldPaths = Set(oldRecords.map(\.path))

    var entries: [DiffEntry] = []
    var unmatchedOld: [FileRecord] = []
    var unmatchedNew: [FileRecord] = []

    for record in oldRecords {
        if let match = newByPath[record.path] {
            if match.sha256 != record.sha256 {
                entries.append(DiffEntry(
                    kind: "modified",
                    oldPath: record.path, newPath: record.path,
                    oldSha256: record.sha256, newSha256: match.sha256,
                    oldSize: record.size, newSize: match.size))
            }
        } else {
            unmatchedOld.append(record)
        }
    }
    for record in newRecords where !oldPaths.contains(record.path) {
        unmatchedNew.append(record)
    }

    var oldByHash: [String: [FileRecord]] = [:]
    for record in unmatchedOld { oldByHash[record.sha256, default: []].append(record) }
    var newByHash: [String: [FileRecord]] = [:]
    for record in unmatchedNew { newByHash[record.sha256, default: []].append(record) }

    var movedOldPaths = Set<String>()
    var movedNewPaths = Set<String>()
    for (hash, olds) in oldByHash where olds.count == 1 {
        guard let news = newByHash[hash], news.count == 1 else { continue }
        let old = olds[0]
        let new = news[0]
        entries.append(DiffEntry(
            kind: "moved",
            oldPath: old.path, newPath: new.path,
            oldSha256: hash, newSha256: hash,
            oldSize: old.size, newSize: new.size))
        movedOldPaths.insert(old.path)
        movedNewPaths.insert(new.path)
    }

    for record in unmatchedOld where !movedOldPaths.contains(record.path) {
        entries.append(DiffEntry(
            kind: "removed",
            oldPath: record.path, newPath: nil,
            oldSha256: record.sha256, newSha256: nil,
            oldSize: record.size, newSize: nil))
    }
    for record in unmatchedNew where !movedNewPaths.contains(record.path) {
        entries.append(DiffEntry(
            kind: "added",
            oldPath: nil, newPath: record.path,
            oldSha256: nil, newSha256: record.sha256,
            oldSize: nil, newSize: record.size))
    }
    return entries
}

func sortEntries(_ entries: [DiffEntry]) -> [DiffEntry] {
    entries.sorted { a, b in
        if let aPath = a.oldPath, let bPath = b.oldPath {
            if aPath != bPath { return utf8Precedes(aPath, bPath) }
        } else if (a.oldPath == nil) != (b.oldPath == nil) {
            return a.oldPath != nil
        }
        if let aPath = a.newPath, let bPath = b.newPath {
            if aPath != bPath { return utf8Precedes(aPath, bPath) }
        } else if (a.newPath == nil) != (b.newPath == nil) {
            return a.newPath != nil
        }
        return utf8Precedes(a.kind, b.kind)
    }
}

func jsonEscape(_ string: String) -> String {
    var out = "\""
    for scalar in string.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case "\u{08}": out += "\\b"
        case "\u{0C}": out += "\\f"
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

private func renderEntry(_ entry: DiffEntry) -> String {
    func field(_ value: String?) -> String { value.map(jsonEscape) ?? "null" }
    func field(_ value: Int64?) -> String { value.map(String.init) ?? "null" }
    return "{"
        + "\"kind\":\(jsonEscape(entry.kind)),"
        + "\"oldPath\":\(field(entry.oldPath)),"
        + "\"newPath\":\(field(entry.newPath)),"
        + "\"oldSha256\":\(field(entry.oldSha256)),"
        + "\"newSha256\":\(field(entry.newSha256)),"
        + "\"oldSize\":\(field(entry.oldSize)),"
        + "\"newSize\":\(field(entry.newSize))"
        + "}"
}

func renderJSON(_ entries: [DiffEntry]) -> String {
    guard !entries.isEmpty else { return "[]" }
    return "[" + entries.map(renderEntry).joined(separator: ",") + "]"
}

func runCompare(oldPath: String, newPath: String) -> Int32 {
    let fileManager = FileManager.default

    var oldIsDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: oldPath, isDirectory: &oldIsDirectory),
          oldIsDirectory.boolValue
    else {
        writeStderr("error: not an existing directory: \(oldPath)\n")
        return 64
    }
    var newIsDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: newPath, isDirectory: &newIsDirectory),
          newIsDirectory.boolValue
    else {
        writeStderr("error: not an existing directory: \(newPath)\n")
        return 64
    }

    let oldRoot = normalizedRoot(oldPath)
    let newRoot = normalizedRoot(newPath)
    guard oldRoot != newRoot else {
        writeStderr("error: OLD and NEW must be different directories\n")
        return 64
    }

    var errors: [CompareError] = []
    let oldFiles = enumerateRegularFiles(root: oldRoot, errors: &errors)
    let newFiles = enumerateRegularFiles(root: newRoot, errors: &errors)

    var oldRecords: [FileRecord] = []
    for relative in oldFiles.sorted(by: utf8Precedes) {
        switch hashFile(root: oldRoot, relativePath: relative) {
        case .success(let record): oldRecords.append(record)
        case .failure(let error): errors.append(error)
        }
    }
    var newRecords: [FileRecord] = []
    for relative in newFiles.sorted(by: utf8Precedes) {
        switch hashFile(root: newRoot, relativePath: relative) {
        case .success(let record): newRecords.append(record)
        case .failure(let error): errors.append(error)
        }
    }

    guard errors.isEmpty else {
        let ordered = errors.enumerated().sorted { a, b in
            a.element.path == b.element.path
                ? a.offset < b.offset
                : utf8Precedes(a.element.path, b.element.path)
        }
        var text = ""
        for error in ordered {
            text += "error: \(error.element.path): \(error.element.message)\n"
        }
        writeStderr(text)
        return 74
    }

    print(renderJSON(sortEntries(computeDiff(oldRecords: oldRecords, newRecords: newRecords))))
    return 0
}

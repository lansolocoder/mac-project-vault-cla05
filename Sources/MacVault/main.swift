import CryptoKit
import Foundation

let exitUsage: Int32 = 64
let exitIOError: Int32 = 74

func writeStderr(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
}

/// Lexicographic comparison of UTF-8 bytes.
func utf8Compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
    if lhs == rhs { return .orderedSame }
    return lhs.utf8.lexicographicallyPrecedes(rhs.utf8) ? .orderedAscending : .orderedDescending
}

/// Compares optional paths, placing nil after any non-nil value.
func compareNullablePath(_ lhs: String?, _ rhs: String?) -> ComparisonResult {
    switch (lhs, rhs) {
    case (nil, nil): return .orderedSame
    case (nil, _): return .orderedDescending
    case (_, nil): return .orderedAscending
    case let (l?, r?): return utf8Compare(l, r)
    }
}

struct FileRecord {
    let sha256: String
    let size: Int
}

struct CompareError {
    let path: String
    let message: String
}

struct DiffEntry {
    let kind: String
    let oldPath: String?
    let newPath: String?
    let oldSha256: String?
    let newSha256: String?
    let oldSize: Int?
    let newSize: Int?
}

/// Hashes one regular file, verifying it stays stable across the read.
/// Returns nil and records an error if the file is unreadable, vanishes,
/// or changes size/mtime between stat and read.
func hashRegularFile(at url: URL, displayPath: String) -> (FileRecord?, CompareError?) {
    let statKeys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
    guard let before = try? url.resourceValues(forKeys: statKeys),
          let sizeBefore = before.fileSize,
          let mtimeBefore = before.contentModificationDate
    else {
        return (nil, CompareError(path: displayPath, message: "cannot read file attributes"))
    }
    do {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        guard let after = try? url.resourceValues(forKeys: statKeys),
              after.fileSize == sizeBefore,
              after.contentModificationDate == mtimeBefore
        else {
            return (nil, CompareError(path: displayPath, message: "file changed while being read"))
        }
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return (FileRecord(sha256: hex, size: sizeBefore), nil)
    } catch {
        return (nil, CompareError(path: displayPath, message: "cannot read file"))
    }
}

/// Recursively enumerates regular files under root without following
/// symbolic links, keyed by `/`-separated relative path.
func enumerateTree(root: String) -> (files: [String: FileRecord], errors: [CompareError]) {
    var records: [String: FileRecord] = [:]
    var errors: [CompareError] = []
    let rootURL = URL(fileURLWithPath: root).standardizedFileURL
    let keys: [URLResourceKey] = [.isRegularFileKey]
    guard let enumerator = FileManager.default.enumerator(
        at: rootURL,
        includingPropertiesForKeys: keys,
        options: [.producesRelativePathURLs],
        errorHandler: { url, _ in
            errors.append(CompareError(path: url.path, message: "cannot enumerate"))
            return true
        }
    ) else {
        errors.append(CompareError(path: rootURL.path, message: "cannot enumerate directory"))
        return (records, errors)
    }
    for case let fileURL as URL in enumerator {
        let relativePath = fileURL.relativePath
        let fullPath = fileURL.path
        guard let values = try? fileURL.resourceValues(forKeys: Set(keys)) else {
            errors.append(CompareError(path: fullPath, message: "cannot read file attributes"))
            continue
        }
        guard values.isRegularFile == true else { continue }
        let (record, error) = hashRegularFile(at: fileURL, displayPath: fullPath)
        if let error {
            errors.append(error)
        } else if let record {
            records[relativePath] = record
        }
    }
    return (records, errors)
}

func buildDiff(oldFiles: [String: FileRecord], newFiles: [String: FileRecord]) -> [DiffEntry] {
    var entries: [DiffEntry] = []
    var removedPaths: [String] = []
    var addedPaths: [String] = []
    for (path, oldRecord) in oldFiles {
        if let newRecord = newFiles[path] {
            if oldRecord.sha256 != newRecord.sha256 {
                entries.append(DiffEntry(
                    kind: "modified", oldPath: path, newPath: path,
                    oldSha256: oldRecord.sha256, newSha256: newRecord.sha256,
                    oldSize: oldRecord.size, newSize: newRecord.size
                ))
            }
        } else {
            removedPaths.append(path)
        }
    }
    for path in newFiles.keys where oldFiles[path] == nil {
        addedPaths.append(path)
    }

    // Match one-sided files by hash: a move only when the hash is unique
    // on both unmatched sides; never guess many-to-many renames.
    var removedByHash: [String: [String]] = [:]
    for path in removedPaths {
        removedByHash[oldFiles[path]!.sha256, default: []].append(path)
    }
    var addedByHash: [String: [String]] = [:]
    for path in addedPaths {
        addedByHash[newFiles[path]!.sha256, default: []].append(path)
    }
    var matchedRemoved: Set<String> = []
    var matchedAdded: Set<String> = []
    for (hash, olds) in removedByHash where olds.count == 1 {
        guard let news = addedByHash[hash], news.count == 1 else { continue }
        let oldPath = olds[0]
        let newPath = news[0]
        let size = oldFiles[oldPath]!.size
        entries.append(DiffEntry(
            kind: "moved", oldPath: oldPath, newPath: newPath,
            oldSha256: hash, newSha256: hash, oldSize: size, newSize: size
        ))
        matchedRemoved.insert(oldPath)
        matchedAdded.insert(newPath)
    }
    for path in removedPaths where !matchedRemoved.contains(path) {
        let record = oldFiles[path]!
        entries.append(DiffEntry(
            kind: "removed", oldPath: path, newPath: nil,
            oldSha256: record.sha256, newSha256: nil, oldSize: record.size, newSize: nil
        ))
    }
    for path in addedPaths where !matchedAdded.contains(path) {
        let record = newFiles[path]!
        entries.append(DiffEntry(
            kind: "added", oldPath: nil, newPath: path,
            oldSha256: nil, newSha256: record.sha256, oldSize: nil, newSize: record.size
        ))
    }

    entries.sort { a, b in
        var result = compareNullablePath(a.oldPath, b.oldPath)
        if result == .orderedSame { result = compareNullablePath(a.newPath, b.newPath) }
        if result == .orderedSame { result = utf8Compare(a.kind, b.kind) }
        return result == .orderedAscending
    }
    return entries
}

func jsonEscape(_ string: String) -> String {
    var result = "\""
    for scalar in string.unicodeScalars {
        switch scalar.value {
        case 0x22: result += "\\\""
        case 0x5C: result += "\\\\"
        case 0x00 ... 0x1F: result += String(format: "\\u%04x", scalar.value)
        default: result.unicodeScalars.append(scalar)
        }
    }
    result += "\""
    return result
}

func jsonStringOrNull(_ value: String?) -> String {
    value.map(jsonEscape) ?? "null"
}

func jsonIntOrNull(_ value: Int?) -> String {
    value.map(String.init) ?? "null"
}

func renderJSON(_ entries: [DiffEntry]) -> String {
    let objects = entries.map { entry in
        "{\"kind\":\(jsonEscape(entry.kind)),"
            + "\"oldPath\":\(jsonStringOrNull(entry.oldPath)),"
            + "\"newPath\":\(jsonStringOrNull(entry.newPath)),"
            + "\"oldSha256\":\(jsonStringOrNull(entry.oldSha256)),"
            + "\"newSha256\":\(jsonStringOrNull(entry.newSha256)),"
            + "\"oldSize\":\(jsonIntOrNull(entry.oldSize)),"
            + "\"newSize\":\(jsonIntOrNull(entry.newSize))}"
    }
    return "[" + objects.joined(separator: ",") + "]"
}

func runCompare(oldRoot: String, newRoot: String) -> Int32 {
    let oldResult = enumerateTree(root: oldRoot)
    let newResult = enumerateTree(root: newRoot)
    let errors = (oldResult.errors + newResult.errors).sorted {
        utf8Compare($0.path, $1.path) == .orderedAscending
    }
    guard errors.isEmpty else {
        for error in errors {
            writeStderr("error: \(error.path): \(error.message)\n")
        }
        return exitIOError
    }
    print(renderJSON(buildDiff(oldFiles: oldResult.files, newFiles: newResult.files)))
    return 0
}

/// Device + inode identity of a directory, following symlinks at the root.
func directoryIdentity(_ path: String) -> (UInt64, UInt64)? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
          let system = attributes[.systemNumber] as? NSNumber,
          let file = attributes[.systemFileNumber] as? NSNumber
    else { return nil }
    return (system.uint64Value, file.uint64Value)
}

func normalizedDirectoryPath(_ path: String) -> String {
    var resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    while resolved.count > 1, resolved.hasSuffix("/") {
        resolved.removeLast()
    }
    return resolved
}

let helpText = """
macvault — local project materials utility

Usage: macvault [--help | --version]
       macvault compare OLD NEW

Commands:
  compare OLD NEW   Recursively compare two directories read-only and print
                    the differences as a JSON array on stdout.

Options:
  -h, --help        Show this help.
  --version         Show the program version.
"""

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.isEmpty || arguments == ["--help"] || arguments == ["-h"] {
    print(helpText)
} else if arguments == ["--version"] {
    print("macvault 0.1.0")
} else if arguments.count == 3, arguments[0] == "compare" {
    let oldPath = arguments[1]
    let newPath = arguments[2]
    var oldIsDirectory: ObjCBool = false
    var newIsDirectory: ObjCBool = false
    let oldExists = FileManager.default.fileExists(atPath: oldPath, isDirectory: &oldIsDirectory)
    let newExists = FileManager.default.fileExists(atPath: newPath, isDirectory: &newIsDirectory)
    guard oldExists, oldIsDirectory.boolValue, newExists, newIsDirectory.boolValue else {
        writeStderr("error: compare requires two existing directories\n")
        exit(exitUsage)
    }
    let samePath = normalizedDirectoryPath(oldPath) == normalizedDirectoryPath(newPath)
    let oldIdentity = directoryIdentity(oldPath)
    let newIdentity = directoryIdentity(newPath)
    let sameInode = oldIdentity != nil && oldIdentity?.0 == newIdentity?.0 && oldIdentity?.1 == newIdentity?.1
    guard !samePath, !sameInode else {
        writeStderr("error: compare requires two different directories\n")
        exit(exitUsage)
    }
    exit(runCompare(oldRoot: oldPath, newRoot: newPath))
} else {
    writeStderr("error: unsupported arguments; use macvault --help\n")
    exit(exitUsage)
}

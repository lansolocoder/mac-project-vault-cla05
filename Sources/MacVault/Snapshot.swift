import Foundation

/// Validates a snapshot relative path: `/`-separated non-empty segments with
/// no absolute prefix, trailing slash, `.` or `..`. Backslashes are ordinary
/// characters and Unicode is never normalized.
func isValidSnapshotPath(_ path: String) -> Bool {
    guard !path.isEmpty, !path.hasPrefix("/"), !path.hasSuffix("/") else {
        return false
    }
    for segment in path.split(separator: "/", omittingEmptySubsequences: false) {
        if segment.isEmpty || segment == "." || segment == ".." {
            return false
        }
    }
    return true
}

private func rfc3339Now() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    return formatter.string(from: Date())
}

private func renderSnapshot(_ records: [FileRecord], capturedAt: String) -> String {
    var out = "{\"version\":1,\"capturedAt\":\(jsonEscape(capturedAt)),\"files\":["
    out += records.map { record in
        "{"
            + "\"path\":\(jsonEscape(record.path)),"
            + "\"sha256\":\(jsonEscape(record.sha256)),"
            + "\"size\":\(record.size)"
            + "}"
    }.joined(separator: ",")
    out += "]}"
    return out
}

/// Returns true when `candidate` is `root` or nested below it. Both paths
/// must be absolute and already standardized (no symlinks, no `..`).
private func isPath(_ candidate: String, inside root: String) -> Bool {
    if candidate == root { return true }
    let prefix = root == "/" ? "/" : root + "/"
    return candidate.hasPrefix(prefix)
}

func runSnapshot(sourcePath: String, snapshotPath: String) -> Int32 {
    let fileManager = FileManager.default

    var sourceIsDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: sourcePath, isDirectory: &sourceIsDirectory),
          sourceIsDirectory.boolValue
    else {
        writeStderr("error: not an existing directory: \(sourcePath)\n")
        return 64
    }

    let sourceRoot = normalizedRoot(sourcePath)

    // The snapshot must be written outside the tree being captured.
    let snapshotURL = URL(fileURLWithPath: snapshotPath)
    let parentPath = snapshotURL.deletingLastPathComponent().standardizedFileURL.path
    let resolvedParent = normalizedRoot(parentPath)
    guard !isPath(resolvedParent, inside: sourceRoot) else {
        writeStderr("error: SNAPSHOT must not be located inside SOURCE: \(snapshotPath)\n")
        return 64
    }

    // Never overwrite an existing snapshot.
    guard !fileManager.fileExists(atPath: snapshotPath) else {
        writeStderr("error: snapshot already exists: \(snapshotPath)\n")
        return 73
    }

    let collected = collectRecords(root: sourceRoot)
    if emitCollectionErrors(collected.errors) {
        return 74
    }

    // Stage in the destination directory, then publish atomically.
    let name = snapshotURL.lastPathComponent.isEmpty
        ? "snapshot" : snapshotURL.lastPathComponent
    let stagingName = ".\(name).tmp-\(UUID().uuidString)"
    let stagingPath = (parentPath as NSString).appendingPathComponent(stagingName)

    let payload = Data((renderSnapshot(collected.records, capturedAt: rfc3339Now()) + "\n").utf8)
    do {
        try payload.write(to: URL(fileURLWithPath: stagingPath))
    } catch {
        try? fileManager.removeItem(atPath: stagingPath)
        writeStderr("error: cannot stage snapshot at \(stagingPath): \(error.localizedDescription)\n")
        return 74
    }

    // Re-check immediately before the rename, and ask the kernel to fail the
    // rename rather than overwrite wherever the flag is available.
    guard !fileManager.fileExists(atPath: snapshotPath) else {
        try? fileManager.removeItem(atPath: stagingPath)
        writeStderr("error: snapshot already exists: \(snapshotPath)\n")
        return 73
    }

    let published: Bool
    var publishErrno: Int32 = 0
    #if canImport(Darwin)
    // RENAME_EXCL: fail with EEXIST instead of replacing the destination.
    if renamex_np(stagingPath, snapshotPath, 0x00000004) != 0 {
        publishErrno = errno
        if publishErrno == EINVAL || publishErrno == ENOTSUP {
            published = rename(stagingPath, snapshotPath) == 0
            publishErrno = errno
        } else {
            published = false
        }
    } else {
        published = true
    }
    #else
    published = rename(stagingPath, snapshotPath) == 0
    publishErrno = errno
    #endif

    guard published else {
        try? fileManager.removeItem(atPath: stagingPath)
        if publishErrno == EEXIST {
            writeStderr("error: snapshot already exists: \(snapshotPath)\n")
            return 73
        }
        writeStderr("error: cannot publish snapshot to \(snapshotPath): "
            + String(cString: strerror(publishErrno)) + "\n")
        return 74
    }
    return 0
}

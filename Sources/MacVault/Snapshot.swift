import Foundation
import Darwin

// MARK: - Snapshot decoding errors

struct SnapshotDecodeError: Error {
    let message: String
}

// MARK: - Minimal strict JSON parser
//
// JSONSerialization is not strict enough for snapshot validation (it accepts
// duplicate keys, non-string fragments, and trailing garbage in some modes),
// so the snapshot format is validated with this small grammar-faithful
// parser instead.

enum JSONValue {
    case null
    case bool(Bool)
    case number(String)                    // raw lexeme; grammar already validated
    case string(String)
    case array([JSONValue])
    case object([(String, JSONValue)])     // preserves member order and duplicates
}

private struct JSONParser {
    private let scalars: [Unicode.Scalar]
    private var index = 0

    init(_ text: String) {
        self.scalars = Array(text.unicodeScalars)
    }

    static func parse(_ text: String) throws -> JSONValue {
        var parser = JSONParser(text)
        let value = try parser.parseValue()
        parser.skipWhitespace()
        guard parser.atEnd else {
            throw SnapshotDecodeError(message: "trailing content after JSON value")
        }
        return value
    }

    private var atEnd: Bool { index >= scalars.count }
    private var current: Unicode.Scalar { scalars[index] }

    private mutating func skipWhitespace() {
        while index < scalars.count {
            switch scalars[index] {
            case " ", "\t", "\n", "\r":
                index += 1
            default:
                return
            }
        }
    }

    private mutating func parseValue() throws -> JSONValue {
        skipWhitespace()
        if atEnd { throw SnapshotDecodeError(message: "unexpected end of input") }
        switch current {
        case "{": return .object(try parseObject())
        case "[": return .array(try parseArray())
        case "\"": return .string(try parseString())
        case "t", "f": return try parseBool()
        case "n":
            try consumeLiteral("null")
            return .null
        default:
            if current == "-" || ("0"..."9").contains(current) {
                return .number(try parseNumber())
            }
            throw SnapshotDecodeError(message: "unexpected character in JSON")
        }
    }

    private mutating func consumeLiteral(_ literal: String) throws {
        for scalar in literal.unicodeScalars {
            guard index < scalars.count, scalars[index] == scalar else {
                throw SnapshotDecodeError(message: "invalid JSON literal")
            }
            index += 1
        }
    }

    private mutating func parseBool() throws -> JSONValue {
        if current == "t" {
            try consumeLiteral("true")
            return .bool(true)
        }
        try consumeLiteral("false")
        return .bool(false)
    }

    private mutating func parseObject() throws -> [(String, JSONValue)] {
        index += 1 // "{"
        var members: [(String, JSONValue)] = []
        skipWhitespace()
        if !atEnd, current == "}" {
            index += 1
            return members
        }
        while true {
            skipWhitespace()
            if atEnd || current != "\"" {
                throw SnapshotDecodeError(message: "expected string key in object")
            }
            let key = try parseString()
            skipWhitespace()
            if atEnd || current != ":" {
                throw SnapshotDecodeError(message: "expected ':' after object key")
            }
            index += 1
            let value = try parseValue()
            members.append((key, value))
            skipWhitespace()
            if atEnd { throw SnapshotDecodeError(message: "unterminated object") }
            switch current {
            case ",":
                index += 1
                skipWhitespace()
                if atEnd || current != "\"" {
                    throw SnapshotDecodeError(message: "trailing comma in object")
                }
            case "}":
                index += 1
                return members
            default:
                throw SnapshotDecodeError(message: "expected ',' or '}' in object")
            }
        }
    }

    private mutating func parseArray() throws -> [JSONValue] {
        index += 1 // "["
        var items: [JSONValue] = []
        skipWhitespace()
        if !atEnd, current == "]" {
            index += 1
            return items
        }
        while true {
            try items.append(parseValue())
            skipWhitespace()
            if atEnd { throw SnapshotDecodeError(message: "unterminated array") }
            switch current {
            case ",":
                index += 1
                skipWhitespace()
                if atEnd || current == "]" {
                    throw SnapshotDecodeError(message: "trailing comma in array")
                }
            case "]":
                index += 1
                return items
            default:
                throw SnapshotDecodeError(message: "expected ',' or ']' in array")
            }
        }
    }

    private mutating func parseString() throws -> String {
        index += 1 // opening quote
        var output = String.UnicodeScalarView()
        while index < scalars.count {
            let scalar = scalars[index]
            switch scalar {
            case "\"":
                index += 1
                return String(output)
            case "\\":
                index += 1
                if atEnd { throw SnapshotDecodeError(message: "unterminated escape sequence") }
                switch scalars[index] {
                case "\"": output.append("\""); index += 1
                case "\\": output.append("\\"); index += 1
                case "/": output.append("/"); index += 1
                case "b": output.append("\u{08}"); index += 1
                case "f": output.append("\u{0C}"); index += 1
                case "n": output.append("\n"); index += 1
                case "r": output.append("\r"); index += 1
                case "t": output.append("\t"); index += 1
                case "u":
                    let codepoint = try parseUnicodeEscape()
                    switch codepoint {
                    case 0xD800...0xDBFF:
                        // A high surrogate must be immediately followed by
                        // an escaped low surrogate; lone surrogates are invalid.
                        guard index + 1 < scalars.count,
                              scalars[index] == "\\", scalars[index + 1] == "u"
                        else {
                            throw SnapshotDecodeError(message: "lone high surrogate in string")
                        }
                        index += 1 // point at the second 'u'
                        let low = try parseUnicodeEscape()
                        guard (0xDC00...0xDFFF).contains(low) else {
                            throw SnapshotDecodeError(message: "invalid surrogate pair in string")
                        }
                        let combined = 0x10000
                            + ((codepoint - 0xD800) << 10)
                            + (low - 0xDC00)
                        output.append(Unicode.Scalar(combined)!)
                    case 0xDC00...0xDFFF:
                        throw SnapshotDecodeError(message: "lone low surrogate in string")
                    default:
                        guard let decoded = Unicode.Scalar(codepoint) else {
                            throw SnapshotDecodeError(message: "invalid unicode escape")
                        }
                        output.append(decoded)
                    }
                default:
                    throw SnapshotDecodeError(message: "invalid escape sequence")
                }
            case "\u{00}"..."\u{1F}":
                throw SnapshotDecodeError(message: "unescaped control character in string")
            default:
                output.append(scalar)
                index += 1
            }
        }
        throw SnapshotDecodeError(message: "unterminated string")
    }

    /// Called with `index` pointing at the 'u' of a `\uXXXX` escape; leaves
    /// `index` right after the fourth hex digit.
    private mutating func parseUnicodeEscape() throws -> UInt32 {
        index += 1 // past 'u'
        guard index + 4 <= scalars.count else {
            throw SnapshotDecodeError(message: "incomplete unicode escape")
        }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let scalar = scalars[index]
            let digit: UInt32
            switch scalar {
            case "0"..."9":
                digit = UInt32(scalar.value - Unicode.Scalar("0").value)
            case "a"..."f":
                digit = UInt32(scalar.value - Unicode.Scalar("a").value) + 10
            case "A"..."F":
                digit = UInt32(scalar.value - Unicode.Scalar("A").value) + 10
            default:
                throw SnapshotDecodeError(message: "invalid hex digit in unicode escape")
            }
            value = value * 16 + digit
            index += 1
        }
        return value
    }

    private mutating func parseNumber() throws -> String {
        let start = index
        if current == "-" { index += 1 }
        guard index < scalars.count else {
            throw SnapshotDecodeError(message: "invalid number")
        }
        if scalars[index] == "0" {
            index += 1
        } else if ("1"..."9").contains(scalars[index]) {
            index += 1
            while index < scalars.count, ("0"..."9").contains(scalars[index]) { index += 1 }
        } else {
            throw SnapshotDecodeError(message: "invalid number")
        }
        if index < scalars.count, scalars[index] == "." {
            index += 1
            guard index < scalars.count, ("0"..."9").contains(scalars[index]) else {
                throw SnapshotDecodeError(message: "invalid number fraction")
            }
            while index < scalars.count, ("0"..."9").contains(scalars[index]) { index += 1 }
        }
        if index < scalars.count, scalars[index] == "e" || scalars[index] == "E" {
            index += 1
            if index < scalars.count, scalars[index] == "+" || scalars[index] == "-" { index += 1 }
            guard index < scalars.count, ("0"..."9").contains(scalars[index]) else {
                throw SnapshotDecodeError(message: "invalid number exponent")
            }
            while index < scalars.count, ("0"..."9").contains(scalars[index]) { index += 1 }
        }
        return String(String.UnicodeScalarView(scalars[start..<index]))
    }
}

// MARK: - Snapshot validation

private let hexDigits = Set("0123456789abcdef".unicodeScalars)

/// Validates a snapshot relative path: non-empty, `/`-separated, no leading
/// or trailing slash, no empty/`.`/`..` segments, no NUL bytes. Backslashes
/// are ordinary characters and Unicode is compared by code points without
/// normalization.
private func isValidRelativePath(_ path: String) -> Bool {
    let scalars = path.unicodeScalars
    guard let first = scalars.first, let last = scalars.last else { return false }
    guard first != "/", last != "/" else { return false }
    var segment = String.UnicodeScalarView()
    for scalar in scalars {
        if scalar == "/" {
            if segment.isEmpty || String(segment) == "." || String(segment) == ".." {
                return false
            }
            segment.removeAll(keepingCapacity: true)
        } else {
            if scalar == "\0" { return false }
            segment.append(scalar)
        }
    }
    return String(segment) != "." && String(segment) != ".."
}

private func isValidSha256(_ value: String) -> Bool {
    value.unicodeScalars.count == 64 && value.unicodeScalars.allSatisfy { hexDigits.contains($0) }
}

private func isValidTimestamp(_ value: String) -> Bool {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    formatter.isLenient = false
    guard let date = formatter.date(from: value) else { return false }
    return formatter.string(from: date) == value
}

private func decodeFiles(_ value: JSONValue) throws -> [FileRecord] {
    guard case .array(let items) = value else {
        throw SnapshotDecodeError(message: "files must be an array")
    }
    var records: [FileRecord] = []
    var seenPaths = Set<String>()
    var previousPath: String?
    for item in items {
        guard case .object(let members) = item else {
            throw SnapshotDecodeError(message: "each file entry must be an object")
        }
        let keys = Set(members.map { $0.0 })
        guard members.count == 3, keys == ["path", "sha256", "size"] else {
            throw SnapshotDecodeError(message: "file entry has missing or extra fields")
        }
        let fields = Dictionary(members, uniquingKeysWith: { $1 })

        guard case .string(let path) = fields["path"], isValidRelativePath(path) else {
            throw SnapshotDecodeError(message: "file entry has an invalid path")
        }
        guard case .string(let sha256) = fields["sha256"], isValidSha256(sha256) else {
            throw SnapshotDecodeError(message: "file entry has an invalid sha256")
        }
        guard case .number(let sizeLexeme) = fields["size"],
              sizeLexeme.first != "-",
              let size = Int64(sizeLexeme, radix: 10), size >= 0
        else {
            throw SnapshotDecodeError(message: "file entry has an invalid size")
        }

        if seenPaths.contains(path) {
            throw SnapshotDecodeError(message: "duplicate path in files: \(path)")
        }
        if let previous = previousPath, !utf8Precedes(previous, path) {
            throw SnapshotDecodeError(message: "file entries are not sorted by path")
        }
        seenPaths.insert(path)
        previousPath = path
        records.append(FileRecord(path: path, sha256: sha256, size: size))
    }
    return records
}

/// Parses and strictly validates a snapshot, returning its file records.
/// Never repairs the file; any problem throws `SnapshotDecodeError`.
private func decodeSnapshot(_ data: Data) throws -> [FileRecord] {
    guard let text = String(data: data, encoding: .utf8) else {
        throw SnapshotDecodeError(message: "snapshot is not valid UTF-8")
    }
    let value = try JSONParser.parse(text)
    guard case .object(let members) = value else {
        throw SnapshotDecodeError(message: "snapshot root must be an object")
    }
    let keys = Set(members.map { $0.0 })
    guard members.count == 3, keys == ["version", "capturedAt", "files"] else {
        throw SnapshotDecodeError(message: "snapshot has missing or extra fields")
    }
    let fields = Dictionary(members, uniquingKeysWith: { $1 })

    guard case .number(let versionLexeme) = fields["version"], versionLexeme == "1" else {
        throw SnapshotDecodeError(message: "unsupported snapshot version")
    }
    guard case .string(let capturedAt) = fields["capturedAt"], isValidTimestamp(capturedAt) else {
        throw SnapshotDecodeError(message: "invalid capturedAt timestamp")
    }
    return try decodeFiles(fields["files"]!)
}

// MARK: - Snapshot rendering

private func utcTimestamp() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    return formatter.string(from: Date())
}

private func renderSnapshot(records: [FileRecord], capturedAt: String) -> String {
    var output = "{\"version\":1,\"capturedAt\":\(jsonEscape(capturedAt)),\"files\":["
    output += records.map { record in
        "{\"path\":\(jsonEscape(record.path)),"
            + "\"sha256\":\(jsonEscape(record.sha256)),"
            + "\"size\":\(record.size)}"
    }.joined(separator: ",")
    output += "]}"
    return output
}

// MARK: - Helpers

private func reportCollectionErrors(_ errors: [CompareError]) {
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
}

private func isPath(_ path: String, inside ancestor: String) -> Bool {
    let ancestorComponents = (ancestor as NSString).pathComponents
    let pathComponents = (path as NSString).pathComponents
    return pathComponents.count >= ancestorComponents.count
        && Array(pathComponents.prefix(ancestorComponents.count)) == ancestorComponents
}

private enum PublishError: Error {
    case destinationExists
    case io(String)
}

/// Writes `json` to a staging file in the destination's own directory and
/// publishes it with `link(2)`, which fails with EEXIST instead of ever
/// overwriting an existing destination. The staging file is removed on every
/// failure path.
private func publishSnapshot(json: String, to snapshotPath: String) throws {
    let bytes = Data(json.utf8)
    let snapshotURL = URL(fileURLWithPath: snapshotPath)
    let parentPath = normalizedRoot(snapshotURL.deletingLastPathComponent().path)
    let tempName = String(
        format: ".macvault-snapshot.%d.%016llx.tmp",
        ProcessInfo.processInfo.processIdentifier,
        UInt64.random(in: 0...UInt64.max))
    let tempPath = (parentPath as NSString).appendingPathComponent(tempName)

    let fd = open(tempPath, O_CREAT | O_EXCL | O_WRONLY, 0o644)
    guard fd >= 0 else {
        throw PublishError.io(
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
                throw PublishError.io("staging write failed: \(String(cString: strerror(errno)))")
            }
            offset += written
        }
        if fsync(fd) != 0 {
            throw PublishError.io("staging sync failed: \(String(cString: strerror(errno)))")
        }
        if close(fd) != 0 {
            throw PublishError.io("staging close failed: \(String(cString: strerror(errno)))")
        }
    } catch {
        close(fd)
        unlink(tempPath)
        throw error
    }

    if link(tempPath, snapshotPath) != 0 {
        if errno == EEXIST {
            unlink(tempPath)
            throw PublishError.destinationExists
        }
        let message = "cannot publish snapshot: \(String(cString: strerror(errno)))"
        unlink(tempPath)
        throw PublishError.io(message)
    }
    unlink(tempPath)
}

// MARK: - `snapshot`

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
    let snapshotURL = URL(fileURLWithPath: snapshotPath)
    let resolvedParent = normalizedRoot(snapshotURL.deletingLastPathComponent().path)
    let resolvedSnapshot = (resolvedParent as NSString)
        .appendingPathComponent(snapshotURL.lastPathComponent)
    guard !isPath(resolvedSnapshot, inside: sourceRoot) else {
        writeStderr("error: SNAPSHOT must not be located inside SOURCE: \(snapshotPath)\n")
        return 64
    }

    guard !fileManager.fileExists(atPath: snapshotPath) else {
        writeStderr("error: snapshot destination already exists: \(snapshotPath)\n")
        return 73
    }

    var errors: [CompareError] = []
    let files = enumerateRegularFiles(root: sourceRoot, errors: &errors)

    var records: [FileRecord] = []
    for relative in files.sorted(by: utf8Precedes) {
        switch hashFile(root: sourceRoot, relativePath: relative) {
        case .success(let record): records.append(record)
        case .failure(let error): errors.append(error)
        }
    }

    guard errors.isEmpty else {
        reportCollectionErrors(errors)
        return 74
    }

    let json = renderSnapshot(records: records, capturedAt: utcTimestamp())
    do {
        try publishSnapshot(json: json, to: snapshotPath)
    } catch PublishError.destinationExists {
        writeStderr("error: snapshot destination already exists: \(snapshotPath)\n")
        return 73
    } catch PublishError.io(let message) {
        writeStderr("error: \(message)\n")
        return 1
    } catch {
        writeStderr("error: \(error)\n")
        return 1
    }
    return 0
}

// MARK: - `snapshot-diff`

func runSnapshotDiff(snapshotPath: String, currentPath: String) -> Int32 {
    let fileManager = FileManager.default

    var currentIsDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: currentPath, isDirectory: &currentIsDirectory),
          currentIsDirectory.boolValue
    else {
        writeStderr("error: not an existing directory: \(currentPath)\n")
        return 64
    }

    let snapshotData: Data
    do {
        snapshotData = try Data(contentsOf: URL(fileURLWithPath: snapshotPath))
    } catch {
        writeStderr("error: cannot read snapshot \(snapshotPath): \(error.localizedDescription)\n")
        return 65
    }

    let snapshotRecords: [FileRecord]
    do {
        snapshotRecords = try decodeSnapshot(snapshotData)
    } catch let error as SnapshotDecodeError {
        writeStderr("error: invalid snapshot \(snapshotPath): \(error.message)\n")
        return 65
    } catch {
        writeStderr("error: invalid snapshot \(snapshotPath)\n")
        return 65
    }

    let currentRoot = normalizedRoot(currentPath)
    var errors: [CompareError] = []
    let files = enumerateRegularFiles(root: currentRoot, errors: &errors)

    var currentRecords: [FileRecord] = []
    for relative in files.sorted(by: utf8Precedes) {
        switch hashFile(root: currentRoot, relativePath: relative) {
        case .success(let record): currentRecords.append(record)
        case .failure(let error): errors.append(error)
        }
    }

    guard errors.isEmpty else {
        reportCollectionErrors(errors)
        return 74
    }

    let entries = sortEntries(computeDiff(
        oldRecords: snapshotRecords,
        newRecords: currentRecords))
    print(renderJSON(entries))
    return 0
}

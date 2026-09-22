import Foundation

// MARK: - Strict JSON parsing

/// A minimal RFC 8259 parser. It is deliberately stricter than
/// JSONSerialization: duplicate object keys, trailing content, unpaired
/// surrogates and control characters inside strings are all rejected, and
/// number spelling is preserved so integer/float distinctions survive.
private enum JSONValue {
    case null
    case bool(Bool)
    /// Token matching `-?(0|[1-9][0-9]*)`.
    case integer(String)
    /// Any other valid JSON number spelling.
    case number(String)
    case string(String)
    case array([JSONValue])
    case object([(key: String, value: JSONValue)])
}

private struct JSONParseError: Error {
    let message: String
}

private struct JSONParser {
    let bytes: [UInt8]
    var index = 0

    static func parse(_ data: Data) throws -> JSONValue {
        var parser = JSONParser(bytes: Array(data))
        let value = try parser.parseValue()
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else {
            throw JSONParseError(message: "trailing content after JSON value")
        }
        return value
    }

    private func error(_ message: String) -> JSONParseError {
        JSONParseError(message: message)
    }

    private mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D:
                index += 1
            default:
                return
            }
        }
    }

    private mutating func parseValue() throws -> JSONValue {
        skipWhitespace()
        guard index < bytes.count else { throw error("unexpected end of JSON") }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): return try parseLiteral("true", .bool(true))
        case UInt8(ascii: "f"): return try parseLiteral("false", .bool(false))
        case UInt8(ascii: "n"): return try parseLiteral("null", .null)
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            return try parseNumber()
        default:
            throw error("unexpected character")
        }
    }

    private mutating func parseLiteral(_ literal: String, _ value: JSONValue) throws -> JSONValue {
        let literalBytes = Array(literal.utf8)
        guard index + literalBytes.count <= bytes.count,
              Array(bytes[index..<index + literalBytes.count]) == literalBytes
        else {
            throw error("invalid literal")
        }
        index += literalBytes.count
        return value
    }

    private mutating func parseObject() throws -> JSONValue {
        index += 1 // '{'
        skipWhitespace()
        var members: [(String, JSONValue)] = []
        var seenKeys = Set<String>()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
            index += 1
            return .object(members)
        }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else {
                throw error("expected string key in object")
            }
            let key = try parseString()
            guard !seenKeys.contains(key) else {
                throw error("duplicate object key: \(key)")
            }
            seenKeys.insert(key)
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else {
                throw error("expected ':' after object key")
            }
            index += 1
            members.append((key, try parseValue()))
            skipWhitespace()
            guard index < bytes.count else { throw error("unterminated object") }
            switch bytes[index] {
            case UInt8(ascii: ","):
                index += 1
            case UInt8(ascii: "}"):
                index += 1
                return .object(members)
            default:
                throw error("expected ',' or '}' in object")
            }
        }
    }

    private mutating func parseArray() throws -> JSONValue {
        index += 1 // '['
        skipWhitespace()
        var elements: [JSONValue] = []
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
            index += 1
            return .array(elements)
        }
        while true {
            elements.append(try parseValue())
            skipWhitespace()
            guard index < bytes.count else { throw error("unterminated array") }
            switch bytes[index] {
            case UInt8(ascii: ","):
                index += 1
            case UInt8(ascii: "]"):
                index += 1
                return .array(elements)
            default:
                throw error("expected ',' or ']' in array")
            }
        }
    }

    private mutating func parseString() throws -> String {
        index += 1 // opening quote
        var output = Data()
        var pendingHighSurrogate: UInt16?

        func appendScalar(_ scalarValue: UInt32) throws {
            guard let scalar = Unicode.Scalar(scalarValue) else {
                throw error("invalid unicode escape")
            }
            var utf8 = [UInt8]()
            UTF8.encode(scalar) { utf8.append($0) }
            output.append(contentsOf: utf8)
        }

        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "\""):
                index += 1
                guard pendingHighSurrogate == nil else {
                    throw error("unpaired UTF-16 surrogate")
                }
                guard let result = String(data: output, encoding: .utf8) else {
                    throw error("invalid UTF-8 in string")
                }
                return result
            case UInt8(ascii: "\\"):
                index += 1
                guard index < bytes.count else { throw error("unterminated escape") }
                switch bytes[index] {
                case UInt8(ascii: "\""):
                    output.append(UInt8(ascii: "\""))
                    index += 1
                case UInt8(ascii: "\\"):
                    output.append(UInt8(ascii: "\\"))
                    index += 1
                case UInt8(ascii: "/"):
                    output.append(UInt8(ascii: "/"))
                    index += 1
                case UInt8(ascii: "b"):
                    output.append(0x08)
                    index += 1
                case UInt8(ascii: "f"):
                    output.append(0x0C)
                    index += 1
                case UInt8(ascii: "n"):
                    output.append(0x0A)
                    index += 1
                case UInt8(ascii: "r"):
                    output.append(0x0D)
                    index += 1
                case UInt8(ascii: "t"):
                    output.append(0x09)
                    index += 1
                case UInt8(ascii: "u"):
                    // parseUnicodeEscape advances index past the four digits.
                    let codeUnit = try parseUnicodeEscape()
                    if let high = pendingHighSurrogate {
                        if (0xDC00...0xDFFF).contains(codeUnit) {
                            let scalarValue = 0x10000
                                + (UInt32(high) - 0xD800) * 0x400
                                + (UInt32(codeUnit) - 0xDC00)
                            try appendScalar(scalarValue)
                            pendingHighSurrogate = nil
                        } else {
                            throw error("unpaired UTF-16 surrogate")
                        }
                    } else if (0xD800...0xDBFF).contains(codeUnit) {
                        pendingHighSurrogate = codeUnit
                    } else if (0xDC00...0xDFFF).contains(codeUnit) {
                        throw error("unpaired UTF-16 surrogate")
                    } else {
                        try appendScalar(UInt32(codeUnit))
                    }
                default:
                    throw error("invalid escape sequence")
                }
            case 0x00...0x1F:
                throw error("unescaped control character in string")
            default:
                output.append(byte)
                index += 1
            }
        }
        throw error("unterminated string")
    }

    private mutating func parseUnicodeEscape() throws -> UInt16 {
        let start = index + 1
        guard start + 4 <= bytes.count else { throw error("short \\u escape") }
        var value: UInt16 = 0
        for byte in bytes[start..<start + 4] {
            let digit: UInt16
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                digit = UInt16(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"):
                digit = UInt16(byte - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"):
                digit = UInt16(byte - UInt8(ascii: "A") + 10)
            default:
                throw error("invalid hex digit in \\u escape")
            }
            value = value * 16 + digit
        }
        index += 5
        return value
    }

    private mutating func parseNumber() throws -> JSONValue {
        let start = index
        if bytes[index] == UInt8(ascii: "-") { index += 1 }
        guard index < bytes.count else { throw error("invalid number") }
        if bytes[index] == UInt8(ascii: "0") {
            index += 1
        } else if (UInt8(ascii: "1")...UInt8(ascii: "9")).contains(bytes[index]) {
            while index < bytes.count,
                  (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
                index += 1
            }
        } else {
            throw error("invalid number")
        }
        var isInteger = true
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            isInteger = false
            index += 1
            guard index < bytes.count,
                  (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index])
            else { throw error("invalid fraction in number") }
            while index < bytes.count,
                  (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
                index += 1
            }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            isInteger = false
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
                index += 1
            }
            guard index < bytes.count,
                  (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index])
            else { throw error("invalid exponent in number") }
            while index < bytes.count,
                  (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
                index += 1
            }
        }
        let raw = String(bytes: bytes[start..<index], encoding: .ascii)!
        return isInteger ? .integer(raw) : .number(raw)
    }
}

// MARK: - Snapshot decoding

private let snapshotFileKeys: Set<String> = ["path", "sha256", "size"]
private let snapshotTopKeys: Set<String> = ["version", "capturedAt", "files"]

private func requireObject(_ value: JSONValue, _ what: String) throws -> [(key: String, value: JSONValue)] {
    guard case .object(let members) = value else {
        throw SnapshotError(message: "\(what) must be a JSON object")
    }
    return members
}

private func requireString(_ value: JSONValue, _ what: String) throws -> String {
    guard case .string(let string) = value else {
        throw SnapshotError(message: "\(what) must be a string")
    }
    return string
}

private func requireArray(_ value: JSONValue, _ what: String) throws -> [JSONValue] {
    guard case .array(let elements) = value else {
        throw SnapshotError(message: "\(what) must be a JSON array")
    }
    return elements
}

private struct SnapshotError: Error {
    let message: String
}

/// Parses and validates a snapshot document without repairing anything.
private func decodeSnapshot(_ data: Data) throws -> [FileRecord] {
    let root: JSONValue
    do {
        root = try JSONParser.parse(data)
    } catch let error as JSONParseError {
        throw SnapshotError(message: "invalid JSON: \(error.message)")
    } catch {
        throw SnapshotError(message: "invalid JSON")
    }

    let members = try requireObject(root, "snapshot")
    let keys = Set(members.map(\.key))
    guard keys == snapshotTopKeys else {
        let missing = snapshotTopKeys.subtracting(keys).sorted()
        let extra = keys.subtracting(snapshotTopKeys).sorted()
        if !missing.isEmpty {
            throw SnapshotError(message: "missing field(s): \(missing.joined(separator: ", "))")
        }
        throw SnapshotError(message: "unexpected field(s): \(extra.joined(separator: ", "))")
    }

    var versionValue: JSONValue?
    var capturedAtValue: JSONValue?
    var filesValue: JSONValue?
    for member in members {
        switch member.key {
        case "version": versionValue = member.value
        case "capturedAt": capturedAtValue = member.value
        case "files": filesValue = member.value
        default: break
        }
    }

    guard case .integer(let versionText) = versionValue,
          let version = Int(versionText), version == 1,
          !versionText.hasPrefix("-")
    else {
        throw SnapshotError(message: "unsupported snapshot version (only version 1 is supported)")
    }
    _ = try requireString(capturedAtValue!, "capturedAt")

    let fileValues = try requireArray(filesValue!, "files")
    var records: [FileRecord] = []
    var seenPaths = Set<String>()
    var previousPath: String?
    for (index, fileValue) in fileValues.enumerated() {
        let what = "files[\(index)]"
        let fileMembers = try requireObject(fileValue, what)
        let fileKeys = Set(fileMembers.map(\.key))
        guard fileKeys == snapshotFileKeys else {
            let missing = snapshotFileKeys.subtracting(fileKeys).sorted()
            let extra = fileKeys.subtracting(snapshotFileKeys).sorted()
            if !missing.isEmpty {
                throw SnapshotError(message: "\(what): missing field(s): \(missing.joined(separator: ", "))")
            }
            throw SnapshotError(message: "\(what): unexpected field(s): \(extra.joined(separator: ", "))")
        }

        var path = ""
        var hash = ""
        var sizeValue: JSONValue?
        for member in fileMembers {
            switch member.key {
            case "path": path = try requireString(member.value, "\(what).path")
            case "sha256": hash = try requireString(member.value, "\(what).sha256")
            case "size": sizeValue = member.value
            default: break
            }
        }

        guard isValidSnapshotPath(path) else {
            throw SnapshotError(message: "\(what): invalid path: \(path)")
        }
        guard !seenPaths.contains(path) else {
            throw SnapshotError(message: "\(what): duplicate path: \(path)")
        }
        if let previousPath, !utf8Precedes(previousPath, path) {
            throw SnapshotError(message: "\(what): files are not sorted by UTF-8 path at: \(path)")
        }

        guard hash.utf8.count == 64,
              hash.unicodeScalars.allSatisfy({
                  ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f")
              })
        else {
            throw SnapshotError(message: "\(what): sha256 must be 64 lowercase hexadecimal characters")
        }

        guard case .integer(let sizeText) = sizeValue,
              !sizeText.hasPrefix("-"),
              let size = Int64(sizeText)
        else {
            throw SnapshotError(message: "\(what): size must be a non-negative integer")
        }

        seenPaths.insert(path)
        previousPath = path
        records.append(FileRecord(path: path, sha256: hash, size: size))
    }
    return records
}

// MARK: - Command entry point

func runSnapshotDiff(snapshotPath: String, currentPath: String) -> Int32 {
    let fileManager = FileManager.default

    let snapshotData: Data
    do {
        snapshotData = try Data(contentsOf: URL(fileURLWithPath: snapshotPath))
    } catch {
        writeStderr("error: cannot read snapshot \(snapshotPath): \(error.localizedDescription)\n")
        return 65
    }

    let oldRecords: [FileRecord]
    do {
        oldRecords = try decodeSnapshot(snapshotData)
    } catch let error as SnapshotError {
        writeStderr("error: invalid snapshot \(snapshotPath): \(error.message)\n")
        return 65
    } catch {
        writeStderr("error: invalid snapshot \(snapshotPath)\n")
        return 65
    }

    var currentIsDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: currentPath, isDirectory: &currentIsDirectory),
          currentIsDirectory.boolValue
    else {
        writeStderr("error: not an existing directory: \(currentPath)\n")
        return 64
    }
    let currentRoot = normalizedRoot(currentPath)

    let collected = collectRecords(root: currentRoot)
    if emitCollectionErrors(collected.errors) {
        return 74
    }

    print(renderJSON(sortEntries(computeDiff(
        oldRecords: oldRecords,
        newRecords: collected.records))))
    return 0
}

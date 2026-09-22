import Foundation
import CryptoKit

/// Streaming helpers for identifying file contents by SHA-256 without loading
/// whole files into memory.
enum FileHash {
    /// Hashes the file at `path` and returns the lowercase hex digest along
    /// with the file's byte count. Throws if the file cannot be read.
    static func sha256AndSize(of path: String) throws -> (sha256: String, size: Int64) {
        let url = URL(fileURLWithPath: path)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        var total: Int64 = 0
        while true {
            guard let chunk = try handle.read(upToCount: 1 << 20) else { break }
            if chunk.isEmpty { break }
            total += Int64(chunk.count)
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return (hex, total)
    }
}

extension Data {
    /// Streams the data into `handle` in fixed-size writes, propagating short
    /// writes or I/O errors instead of relying on `write(_:)` conveniences.
    func writeAll(to handle: FileHandle) throws {
        try withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var written = 0
            while written < count {
                let result = Foundation.write(handle.fileDescriptor,
                                              base.advanced(by: written),
                                              count - written)
                if result < 0 {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                                  userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
                }
                written += result
            }
        }
    }
}

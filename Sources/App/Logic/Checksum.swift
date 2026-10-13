import Foundation
import CryptoKit

enum Checksum {
    /// Streaming SHA-1 (hex) of a file, computed off the main actor.
    /// Immich identifies duplicates by the SHA-1 of the original file bytes.
    static func sha1Hex(of url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = Insecure.SHA1()
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
}

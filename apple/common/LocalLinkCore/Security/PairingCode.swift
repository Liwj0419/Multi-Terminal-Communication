import CryptoKit
import Foundation

public enum PairingCode {
  public static func derive(localPublicKey: String, remotePublicKey: String) -> String {
    let ordered = [localPublicKey, remotePublicKey].sorted().joined(separator: "|")
    let digest = SHA256.hash(data: Data(ordered.utf8))
    let number = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
    return String(format: "%06d", number)
  }
}

public enum Checksum {
  public static func sha256Hex(for data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  public static func sha256Hex(forFileAt url: URL) throws -> String {
    let data = try Data(contentsOf: url)
    return sha256Hex(for: data)
  }
}

import Foundation

public protocol TrustedPeerStoring {
  func loadTrustedPeers() throws -> [TrustedPeer]
  func saveTrustedPeer(_ peer: TrustedPeer) throws
  func forgetTrustedPeer(deviceID: String) throws
  func isTrusted(deviceID: String, publicKey: String) throws -> Bool
}

public final class JSONTrustedPeerStore: TrustedPeerStoring {
  private let fileURL: URL

  public init(fileURL: URL? = nil) {
    if let fileURL {
      self.fileURL = fileURL
    } else {
      let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
      self.fileURL = support.appendingPathComponent("LocalLink/trusted-peers.json")
    }
  }

  public func loadTrustedPeers() throws -> [TrustedPeer] {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
    let data = try Data(contentsOf: fileURL)
    return try JSONDecoder.localLink.decode([TrustedPeer].self, from: data)
  }

  public func saveTrustedPeer(_ peer: TrustedPeer) throws {
    var peers = try loadTrustedPeers().filter { $0.deviceID != peer.deviceID }
    peers.append(peer)
    try save(peers.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending })
  }

  public func forgetTrustedPeer(deviceID: String) throws {
    try save(try loadTrustedPeers().filter { $0.deviceID != deviceID })
  }

  public func isTrusted(deviceID: String, publicKey: String) throws -> Bool {
    try loadTrustedPeers().contains { $0.deviceID == deviceID && $0.publicKey == publicKey }
  }

  private func save(_ peers: [TrustedPeer]) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let data = try JSONEncoder.localLink.encode(peers)
    try data.write(to: fileURL, options: [.atomic])
  }
}

public final class InMemoryTrustedPeerStore: TrustedPeerStoring {
  public var peers: [TrustedPeer]

  public init(peers: [TrustedPeer] = []) {
    self.peers = peers
  }

  public func loadTrustedPeers() throws -> [TrustedPeer] {
    peers
  }

  public func saveTrustedPeer(_ peer: TrustedPeer) throws {
    peers.removeAll { $0.deviceID == peer.deviceID }
    peers.append(peer)
  }

  public func forgetTrustedPeer(deviceID: String) throws {
    peers.removeAll { $0.deviceID == deviceID }
  }

  public func isTrusted(deviceID: String, publicKey: String) throws -> Bool {
    peers.contains { $0.deviceID == deviceID && $0.publicKey == publicKey }
  }
}

public protocol ConversationMessageStoring {
  func loadMessages() throws -> [ConversationMessage]
  func saveMessages(_ messages: [ConversationMessage]) throws
  func clearMessages(peerID: String) throws
}

public final class JSONConversationMessageStore: ConversationMessageStoring {
  private let fileURL: URL

  public init(fileURL: URL? = nil) {
    if let fileURL {
      self.fileURL = fileURL
    } else {
      let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
      self.fileURL = support.appendingPathComponent("LocalLink/messages.json")
    }
  }

  public func loadMessages() throws -> [ConversationMessage] {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
    let data = try Data(contentsOf: fileURL)
    return try JSONDecoder.localLink.decode([ConversationMessage].self, from: data)
  }

  public func saveMessages(_ messages: [ConversationMessage]) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let sorted = messages.sorted { $0.createdAt < $1.createdAt }
    let data = try JSONEncoder.localLink.encode(sorted)
    try data.write(to: fileURL, options: [.atomic])
  }

  public func clearMessages(peerID: String) throws {
    try saveMessages(try loadMessages().filter { $0.peerID != peerID })
  }
}

public final class InMemoryConversationMessageStore: ConversationMessageStoring {
  public var messages: [ConversationMessage]

  public init(messages: [ConversationMessage] = []) {
    self.messages = messages
  }

  public func loadMessages() throws -> [ConversationMessage] {
    messages
  }

  public func saveMessages(_ messages: [ConversationMessage]) throws {
    self.messages = messages
  }

  public func clearMessages(peerID: String) throws {
    messages.removeAll { $0.peerID == peerID }
  }
}

public protocol TransferItemStoring {
  func loadTransfers() throws -> [TransferItem]
  func saveTransfers(_ transfers: [TransferItem]) throws
  func clearTransfers(peerID: String) throws
}

public final class JSONTransferItemStore: TransferItemStoring {
  private let fileURL: URL

  public init(fileURL: URL? = nil) {
    if let fileURL {
      self.fileURL = fileURL
    } else {
      let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
      self.fileURL = support.appendingPathComponent("LocalLink/transfers.json")
    }
  }

  public func loadTransfers() throws -> [TransferItem] {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
    let data = try Data(contentsOf: fileURL)
    return try JSONDecoder.localLink.decode([TransferItem].self, from: data)
  }

  public func saveTransfers(_ transfers: [TransferItem]) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let sorted = transfers.sorted { $0.createdAt < $1.createdAt }
    let data = try JSONEncoder.localLink.encode(sorted)
    try data.write(to: fileURL, options: [.atomic])
  }

  public func clearTransfers(peerID: String) throws {
    try saveTransfers(try loadTransfers().filter { $0.peerID != peerID })
  }
}

public final class InMemoryTransferItemStore: TransferItemStoring {
  public var transfers: [TransferItem]

  public init(transfers: [TransferItem] = []) {
    self.transfers = transfers
  }

  public func loadTransfers() throws -> [TransferItem] {
    transfers
  }

  public func saveTransfers(_ transfers: [TransferItem]) throws {
    self.transfers = transfers
  }

  public func clearTransfers(peerID: String) throws {
    transfers.removeAll { $0.peerID == peerID }
  }
}

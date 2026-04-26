import Foundation

public enum TransferDirection: String, Codable, Sendable {
  case incoming
  case outgoing
}

public enum TransferStatus: String, Codable, Sendable {
  case offered
  case inProgress
  case complete
  case cancelled
  case failed
}

public struct TransferItem: Identifiable, Codable, Equatable, Sendable {
  public var id: UUID
  public var peerID: String
  public var direction: TransferDirection
  public var fileName: String
  public var contentType: String?
  public var totalBytes: Int64
  public var completedBytes: Int64
  public var checksum: String?
  public var status: TransferStatus
  public var errorMessage: String?
  public var localPath: String?
  public var downloadedPath: String?
  public var createdAt: Date

  public var progress: Double {
    guard totalBytes > 0 else { return status == .complete ? 1 : 0 }
    return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
  }

  public var isPicture: Bool {
    let lowerName = fileName.lowercased()
    if contentType?.lowercased().hasPrefix("image/") == true { return true }
    return [".jpg", ".jpeg", ".png", ".gif", ".heic", ".webp", ".tiff"].contains { lowerName.hasSuffix($0) }
  }

  public var isAvailableLocally: Bool {
    localPath != nil || downloadedPath != nil
  }

  public init(
    id: UUID = UUID(),
    peerID: String,
    direction: TransferDirection,
    fileName: String,
    contentType: String? = nil,
    totalBytes: Int64,
    completedBytes: Int64 = 0,
    checksum: String? = nil,
    status: TransferStatus = .offered,
    errorMessage: String? = nil,
    localPath: String? = nil,
    downloadedPath: String? = nil,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.peerID = peerID
    self.direction = direction
    self.fileName = fileName
    self.contentType = contentType
    self.totalBytes = totalBytes
    self.completedBytes = completedBytes
    self.checksum = checksum
    self.status = status
    self.errorMessage = errorMessage
    self.localPath = localPath
    self.downloadedPath = downloadedPath
    self.createdAt = createdAt
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case peerID
    case direction
    case fileName
    case contentType
    case totalBytes
    case completedBytes
    case checksum
    case status
    case errorMessage
    case localPath
    case downloadedPath
    case createdAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    peerID = try container.decode(String.self, forKey: .peerID)
    direction = try container.decode(TransferDirection.self, forKey: .direction)
    fileName = try container.decode(String.self, forKey: .fileName)
    contentType = try container.decodeIfPresent(String.self, forKey: .contentType)
    totalBytes = try container.decode(Int64.self, forKey: .totalBytes)
    completedBytes = try container.decode(Int64.self, forKey: .completedBytes)
    checksum = try container.decodeIfPresent(String.self, forKey: .checksum)
    status = try container.decode(TransferStatus.self, forKey: .status)
    errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
    localPath = try container.decodeIfPresent(String.self, forKey: .localPath)
    downloadedPath = try container.decodeIfPresent(String.self, forKey: .downloadedPath)
    createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
  }
}

public struct ConversationMessage: Identifiable, Codable, Equatable, Sendable {
  public var id: UUID
  public var peerID: String
  public var isOutgoing: Bool
  public var text: String
  public var createdAt: Date

  public init(
    id: UUID = UUID(),
    peerID: String,
    isOutgoing: Bool,
    text: String,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.peerID = peerID
    self.isOutgoing = isOutgoing
    self.text = text
    self.createdAt = createdAt
  }
}

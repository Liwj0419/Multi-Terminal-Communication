import Foundation
import Network

public struct TrustedPeer: Codable, Equatable, Identifiable, Sendable {
  public var id: String { deviceID }

  public var deviceID: String
  public var displayName: String
  public var platform: DevicePlatform
  public var publicKey: String
  public var pairedAt: Date
  public var lastSeenAt: Date?
  public var lastHost: String?
  public var lastPort: UInt16?

  public init(
    deviceID: String,
    displayName: String,
    platform: DevicePlatform,
    publicKey: String,
    pairedAt: Date = Date(),
    lastSeenAt: Date? = nil,
    lastHost: String? = nil,
    lastPort: UInt16? = nil
  ) {
    self.deviceID = deviceID
    self.displayName = displayName
    self.platform = platform
    self.publicKey = publicKey
    self.pairedAt = pairedAt
    self.lastSeenAt = lastSeenAt
    self.lastHost = lastHost
    self.lastPort = lastPort
  }
}

public struct DiscoveredPeer: Identifiable, Equatable, @unchecked Sendable {
  public var id: String { identity.deviceID }

  public var identity: DeviceIdentity
  public var endpoint: NWEndpoint?
  public var endpointDescription: String
  public var isTrusted: Bool
  public var discoveredAt: Date

  public init(
    identity: DeviceIdentity,
    endpoint: NWEndpoint?,
    endpointDescription: String,
    isTrusted: Bool,
    discoveredAt: Date = Date()
  ) {
    self.identity = identity
    self.endpoint = endpoint
    self.endpointDescription = endpointDescription
    self.isTrusted = isTrusted
    self.discoveredAt = discoveredAt
  }

  public static func == (lhs: DiscoveredPeer, rhs: DiscoveredPeer) -> Bool {
    lhs.identity == rhs.identity &&
      lhs.endpointDescription == rhs.endpointDescription &&
      lhs.isTrusted == rhs.isTrusted
  }
}

public extension TrustedPeer {
  init(
    identity: DeviceIdentity,
    pairedAt: Date = Date(),
    lastSeenAt: Date? = nil,
    lastHost: String? = nil,
    lastPort: UInt16? = nil
  ) {
    self.init(
      deviceID: identity.deviceID,
      displayName: identity.displayName,
      platform: identity.platform,
      publicKey: identity.publicKey,
      pairedAt: pairedAt,
      lastSeenAt: lastSeenAt,
      lastHost: lastHost,
      lastPort: lastPort
    )
  }
}

import Foundation

public enum DevicePlatform: String, Codable, CaseIterable, Sendable {
  case iOS
  case macOS
  case android
  case windows
  case unknown
}

public struct DeviceIdentity: Codable, Equatable, Hashable, Sendable {
  public var deviceID: String
  public var displayName: String
  public var platform: DevicePlatform
  public var publicKey: String
  public var protocolVersion: Int

  public init(
    deviceID: String,
    displayName: String,
    platform: DevicePlatform,
    publicKey: String,
    protocolVersion: Int = 1
  ) {
    self.deviceID = deviceID
    self.displayName = displayName
    self.platform = platform
    self.publicKey = publicKey
    self.protocolVersion = protocolVersion
  }
}

public struct LocalDeviceIdentity {
  public var identity: DeviceIdentity
  public var privateKeyData: Data

  public init(identity: DeviceIdentity, privateKeyData: Data) {
    self.identity = identity
    self.privateKeyData = privateKeyData
  }
}

public extension DevicePlatform {
  static var currentApplePlatform: DevicePlatform {
    #if os(iOS)
    return .iOS
    #elseif os(macOS)
    return .macOS
    #else
    return .unknown
    #endif
  }
}

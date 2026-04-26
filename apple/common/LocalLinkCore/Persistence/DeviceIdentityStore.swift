import CryptoKit
import Foundation
import Security

public enum DeviceIdentityStoreError: Error {
  case corruptStoredIdentity
  case keychain(OSStatus)
}

public protocol DeviceIdentityStoring {
  func loadOrCreate(displayName: String, platform: DevicePlatform) throws -> LocalDeviceIdentity
  func updateDisplayName(_ displayName: String) throws -> LocalDeviceIdentity
}

public final class KeychainDeviceIdentityStore: DeviceIdentityStoring {
  private let service: String
  private let account: String
  private let defaults: UserDefaults
  private let identityKey: String

  public init(
    service: String = "com.local.LocalLink.identity",
    account: String = "local-device-private-key",
    defaults: UserDefaults = .standard
  ) {
    self.service = service
    self.account = account
    self.defaults = defaults
    self.identityKey = "\(service).deviceIdentity"
  }

  public func loadOrCreate(displayName: String, platform: DevicePlatform) throws -> LocalDeviceIdentity {
    if let storedIdentity = try loadIdentity(), let privateKeyData = try loadPrivateKey() {
      return LocalDeviceIdentity(identity: storedIdentity, privateKeyData: privateKeyData)
    }

    let local = KeyPairFactory.makeIdentity(displayName: displayName, platform: platform)
    try save(local)
    return local
  }

  public func updateDisplayName(_ displayName: String) throws -> LocalDeviceIdentity {
    guard var identity = try loadIdentity(), let privateKeyData = try loadPrivateKey() else {
      throw DeviceIdentityStoreError.corruptStoredIdentity
    }
    identity.displayName = displayName
    let local = LocalDeviceIdentity(identity: identity, privateKeyData: privateKeyData)
    try save(local)
    return local
  }

  private func loadIdentity() throws -> DeviceIdentity? {
    guard let data = defaults.data(forKey: identityKey) else { return nil }
    return try JSONDecoder.localLink.decode(DeviceIdentity.self, from: data)
  }

  private func save(_ local: LocalDeviceIdentity) throws {
    defaults.set(try JSONEncoder.localLink.encode(local.identity), forKey: identityKey)
    try savePrivateKey(local.privateKeyData)
  }

  private func loadPrivateKey() throws -> Data? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne
    ]

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw DeviceIdentityStoreError.keychain(status) }
    return item as? Data
  }

  private func savePrivateKey(_ data: Data) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account
    ]
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ]

    let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecSuccess { return }
    if status != errSecItemNotFound { throw DeviceIdentityStoreError.keychain(status) }

    var addQuery = query
    attributes.forEach { addQuery[$0.key] = $0.value }
    let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
    guard addStatus == errSecSuccess else { throw DeviceIdentityStoreError.keychain(addStatus) }
  }
}

public final class InMemoryDeviceIdentityStore: DeviceIdentityStoring {
  public var local: LocalDeviceIdentity?

  public init(local: LocalDeviceIdentity? = nil) {
    self.local = local
  }

  public func loadOrCreate(displayName: String, platform: DevicePlatform) throws -> LocalDeviceIdentity {
    if let local { return local }
    let created = KeyPairFactory.makeIdentity(displayName: displayName, platform: platform)
    local = created
    return created
  }

  public func updateDisplayName(_ displayName: String) throws -> LocalDeviceIdentity {
    let current = try loadOrCreate(displayName: displayName, platform: .currentApplePlatform)
    var identity = current.identity
    identity.displayName = displayName
    let updated = LocalDeviceIdentity(identity: identity, privateKeyData: current.privateKeyData)
    local = updated
    return updated
  }
}

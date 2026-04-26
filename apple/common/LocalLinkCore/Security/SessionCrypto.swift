import CryptoKit
import Foundation

public enum SessionCryptoError: Error, Equatable {
  case invalidPrivateKey
  case invalidPublicKey
  case invalidSealedBox
}

public struct SessionCrypto {
  public var key: SymmetricKey

  public init(localPrivateKeyData: Data, remotePublicKeyBase64: String) throws {
    guard let remotePublicKeyData = Data(base64Encoded: remotePublicKeyBase64) else {
      throw SessionCryptoError.invalidPublicKey
    }

    let privateKey: Curve25519.KeyAgreement.PrivateKey
    let remotePublicKey: Curve25519.KeyAgreement.PublicKey

    do {
      privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: localPrivateKeyData)
      remotePublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remotePublicKeyData)
    } catch {
      throw SessionCryptoError.invalidPrivateKey
    }

    let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: remotePublicKey)
    self.key = sharedSecret.hkdfDerivedSymmetricKey(
      using: SHA256.self,
      salt: Data("LocalLink-v1".utf8),
      sharedInfo: Data("frames".utf8),
      outputByteCount: 32
    )
  }

  public init(key: SymmetricKey) {
    self.key = key
  }

  public func seal(_ payload: Data) throws -> Data {
    try ChaChaPoly.seal(payload, using: key).combined
  }

  public func open(_ sealedPayload: Data) throws -> Data {
    do {
      return try ChaChaPoly.open(try ChaChaPoly.SealedBox(combined: sealedPayload), using: key)
    } catch {
      throw SessionCryptoError.invalidSealedBox
    }
  }
}

public enum KeyPairFactory {
  public static func makeIdentity(
    deviceID: String = UUID().uuidString,
    displayName: String,
    platform: DevicePlatform
  ) -> LocalDeviceIdentity {
    let privateKey = Curve25519.KeyAgreement.PrivateKey()
    let publicKey = privateKey.publicKey.rawRepresentation.base64EncodedString()
    let identity = DeviceIdentity(
      deviceID: deviceID,
      displayName: displayName,
      platform: platform,
      publicKey: publicKey
    )
    return LocalDeviceIdentity(identity: identity, privateKeyData: privateKey.rawRepresentation)
  }
}

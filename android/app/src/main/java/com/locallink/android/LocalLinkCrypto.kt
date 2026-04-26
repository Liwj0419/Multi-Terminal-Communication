package com.locallink.android

import org.bouncycastle.crypto.agreement.X25519Agreement
import org.bouncycastle.crypto.digests.SHA256Digest
import org.bouncycastle.crypto.generators.HKDFBytesGenerator
import org.bouncycastle.crypto.modes.ChaCha20Poly1305
import org.bouncycastle.crypto.params.AEADParameters
import org.bouncycastle.crypto.params.HKDFParameters
import org.bouncycastle.crypto.params.KeyParameter
import org.bouncycastle.crypto.params.X25519PrivateKeyParameters
import org.bouncycastle.crypto.params.X25519PublicKeyParameters
import java.security.SecureRandom

class SessionCrypto(
  localPrivateKey: ByteArray,
  remotePublicKeyBase64: String
) {
  private val key: ByteArray

  init {
    val privateKey = X25519PrivateKeyParameters(localPrivateKey, 0)
    val remotePublicKey = X25519PublicKeyParameters(LocalLinkHashes.unbase64(remotePublicKeyBase64), 0)
    val agreement = X25519Agreement()
    agreement.init(privateKey)
    val shared = ByteArray(agreement.agreementSize)
    agreement.calculateAgreement(remotePublicKey, shared, 0)

    key = ByteArray(32)
    HKDFBytesGenerator(SHA256Digest()).apply {
      init(
        HKDFParameters(
          shared,
          "LocalLink-v1".toByteArray(Charsets.UTF_8),
          "frames".toByteArray(Charsets.UTF_8)
        )
      )
      generateBytes(key, 0, key.size)
    }
  }

  fun seal(payload: ByteArray): ByteArray {
    val nonce = ByteArray(12)
    SecureRandom().nextBytes(nonce)
    val cipher = ChaCha20Poly1305()
    cipher.init(true, AEADParameters(KeyParameter(key), 128, nonce))
    val encrypted = ByteArray(cipher.getOutputSize(payload.size))
    val len = cipher.processBytes(payload, 0, payload.size, encrypted, 0)
    cipher.doFinal(encrypted, len)
    return nonce + encrypted
  }

  fun open(sealed: ByteArray): ByteArray {
    require(sealed.size >= 12)
    val nonce = sealed.copyOfRange(0, 12)
    val encrypted = sealed.copyOfRange(12, sealed.size)
    val cipher = ChaCha20Poly1305()
    cipher.init(false, AEADParameters(KeyParameter(key), 128, nonce))
    val output = ByteArray(cipher.getOutputSize(encrypted.size))
    val len = cipher.processBytes(encrypted, 0, encrypted.size, output, 0)
    val finalLen = cipher.doFinal(output, len)
    return output.copyOf(len + finalLen)
  }

  companion object {
    fun makeIdentity(displayName: String): LocalIdentity {
      val privateKey = X25519PrivateKeyParameters(SecureRandom())
      val privateBytes = ByteArray(32)
      privateKey.encode(privateBytes, 0)
      val publicBytes = ByteArray(32)
      privateKey.generatePublicKey().encode(publicBytes, 0)
      val identity = DeviceIdentity(
        deviceID = java.util.UUID.randomUUID().toString(),
        displayName = displayName,
        publicKey = LocalLinkHashes.base64(publicBytes)
      )
      return LocalIdentity(identity, privateBytes)
    }
  }
}

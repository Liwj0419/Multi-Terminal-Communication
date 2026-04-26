package com.locallink.android

import android.util.Base64
import org.json.JSONObject
import java.security.MessageDigest
import java.time.Instant
import java.util.UUID

enum class FrameKind {
  hello,
  pairRequest,
  pairConfirm,
  pairAccepted,
  auth,
  text,
  fileOffer,
  fileChunk,
  fileComplete,
  cancel,
  disconnect,
  error
}

data class DeviceIdentity(
  val deviceID: String,
  val displayName: String,
  val platform: String = "android",
  val publicKey: String,
  val protocolVersion: Int = 1
) {
  fun toJson(): JSONObject = JSONObject()
    .put("deviceID", deviceID)
    .put("displayName", displayName)
    .put("platform", platform)
    .put("publicKey", publicKey)
    .put("protocolVersion", protocolVersion)

  companion object {
    fun fromJson(json: JSONObject): DeviceIdentity = DeviceIdentity(
      deviceID = json.getString("deviceID"),
      displayName = json.optString("displayName", "Android"),
      platform = json.optString("platform", "unknown"),
      publicKey = json.optString("publicKey", ""),
      protocolVersion = json.optInt("protocolVersion", 1)
    )
  }
}

data class LocalIdentity(
  val identity: DeviceIdentity,
  val privateKey: ByteArray
)

data class DiscoveredPeer(
  val identity: DeviceIdentity,
  val host: String,
  val port: Int,
  val trusted: Boolean = false
)

data class WireFrame(
  val kind: FrameKind,
  val senderID: String,
  val recipientID: String? = null,
  val transferID: String? = null,
  val metadata: Map<String, String> = emptyMap(),
  val payload: ByteArray = ByteArray(0),
  val id: String = UUID.randomUUID().toString(),
  val timestamp: String = Instant.now().toString()
)

data class MessageItem(
  val peerID: String,
  val outgoing: Boolean,
  val text: String,
  val createdAt: Long = System.currentTimeMillis()
)

data class TransferItem(
  val id: String,
  val peerID: String,
  val outgoing: Boolean,
  val fileName: String,
  val contentType: String?,
  val totalBytes: Long,
  val completedBytes: Long = 0,
  val checksum: String? = null,
  val complete: Boolean = false,
  val downloaded: Boolean = false
) {
  val isPicture: Boolean
    get() {
      val lower = fileName.lowercase()
      return contentType?.lowercase()?.startsWith("image/") == true ||
        lower.endsWith(".jpg") ||
        lower.endsWith(".jpeg") ||
        lower.endsWith(".png") ||
        lower.endsWith(".gif") ||
        lower.endsWith(".webp") ||
        lower.endsWith(".heic")
    }
}

object LocalLinkHashes {
  fun sha256Hex(data: ByteArray): String {
    val digest = MessageDigest.getInstance("SHA-256").digest(data)
    return digest.joinToString("") { "%02x".format(it) }
  }

  fun pairingCode(localPublicKey: String, remotePublicKey: String): String {
    val joined = listOf(localPublicKey, remotePublicKey).sorted().joinToString("|")
    val digest = MessageDigest.getInstance("SHA-256").digest(joined.toByteArray(Charsets.UTF_8))
    var value = 0L
    for (i in 0 until 4) {
      value = (value shl 8) or (digest[i].toInt() and 0xff).toLong()
    }
    return "%06d".format(value % 1_000_000)
  }

  fun base64(data: ByteArray): String = Base64.encodeToString(data, Base64.NO_WRAP)
  fun unbase64(value: String): ByteArray = Base64.decode(value, Base64.NO_WRAP)
}

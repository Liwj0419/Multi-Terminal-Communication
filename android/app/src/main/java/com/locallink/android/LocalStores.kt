package com.locallink.android

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

class LocalStores(private val context: Context) {
  private val prefs = context.getSharedPreferences("LocalLink", Context.MODE_PRIVATE)

  fun loadOrCreateIdentity(): LocalIdentity {
    val id = prefs.getString("deviceID", null)
    val name = prefs.getString("displayName", null)
    val publicKey = prefs.getString("publicKey", null)
    val privateKey = prefs.getString("privateKey", null)
    if (id != null && name != null && publicKey != null && privateKey != null) {
      return LocalIdentity(
        DeviceIdentity(id, name, "android", publicKey),
        LocalLinkHashes.unbase64(privateKey)
      )
    }

    val created = SessionCrypto.makeIdentity(android.os.Build.MODEL ?: "Android")
    prefs.edit()
      .putString("deviceID", created.identity.deviceID)
      .putString("displayName", created.identity.displayName)
      .putString("publicKey", created.identity.publicKey)
      .putString("privateKey", LocalLinkHashes.base64(created.privateKey))
      .apply()
    return created
  }

  fun updateDisplayName(displayName: String): LocalIdentity {
    val current = loadOrCreateIdentity()
    val trimmed = displayName.trim().ifBlank { current.identity.displayName }
    prefs.edit().putString("displayName", trimmed).apply()
    return current.copy(identity = current.identity.copy(displayName = trimmed))
  }

  fun trustedPeers(): List<TrustedPeer> {
    val array = JSONArray(prefs.getString("trustedPeers", "[]"))
    return (0 until array.length()).map { index ->
      val json = array.getJSONObject(index)
      if (json.has("identity")) {
        TrustedPeer(
          identity = DeviceIdentity.fromJson(json.getJSONObject("identity")),
          lastHost = json.optString("lastHost", "").ifBlank { null },
          lastPort = json.optInt("lastPort", 0)
        )
      } else {
        TrustedPeer(DeviceIdentity.fromJson(json))
      }
    }
  }

  fun isTrusted(identity: DeviceIdentity): Boolean =
    trustedPeers().any { it.deviceID == identity.deviceID && it.publicKey == identity.publicKey }

  fun trustedPeer(identity: DeviceIdentity): TrustedPeer? =
    trustedPeers().firstOrNull { it.deviceID == identity.deviceID && it.publicKey == identity.publicKey }

  fun saveTrusted(identity: DeviceIdentity, host: String? = null, port: Int = 0) {
    val current = trustedPeers()
    val existing = current.firstOrNull { it.deviceID == identity.deviceID }
    val peers = current.filterNot { it.deviceID == identity.deviceID }.toMutableList()
    val lastHost = host?.takeIf { it.isNotBlank() } ?: existing?.lastHost
    val lastPort = if (port > 0) port else existing?.lastPort ?: 0
    peers += TrustedPeer(identity, lastHost, lastPort)
    val array = JSONArray()
    peers.forEach { peer ->
      array.put(
        JSONObject()
          .put("identity", peer.identity.toJson())
          .put("lastHost", peer.lastHost ?: "")
          .put("lastPort", peer.lastPort)
      )
    }
    prefs.edit().putString("trustedPeers", array.toString()).apply()
  }

  fun forget(deviceID: String) {
    val array = JSONArray()
    trustedPeers().filterNot { it.deviceID == deviceID }.forEach { peer ->
      array.put(
        JSONObject()
          .put("identity", peer.identity.toJson())
          .put("lastHost", peer.lastHost ?: "")
          .put("lastPort", peer.lastPort)
      )
    }
    prefs.edit().putString("trustedPeers", array.toString()).apply()
  }

  fun saveMessages(messages: List<MessageItem>) {
    val array = JSONArray()
    messages.forEach {
      array.put(
        JSONObject()
          .put("peerID", it.peerID)
          .put("outgoing", it.outgoing)
          .put("text", it.text)
          .put("createdAt", it.createdAt)
      )
    }
    prefs.edit().putString("messages", array.toString()).apply()
  }

  fun loadMessages(): MutableList<MessageItem> {
    val array = JSONArray(prefs.getString("messages", "[]"))
    val messages = mutableListOf<MessageItem>()
    for (index in 0 until array.length()) {
      val json = array.getJSONObject(index)
      messages += MessageItem(
        peerID = json.getString("peerID"),
        outgoing = json.getBoolean("outgoing"),
        text = json.getString("text"),
        createdAt = json.optLong("createdAt", System.currentTimeMillis())
      )
    }
    return messages
  }
}

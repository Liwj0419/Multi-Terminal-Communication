package com.locallink.android

import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID

object FrameCodec {
  private const val maxHeaderBytes = 64 * 1024
  private const val maxPayloadBytes = 8 * 1024 * 1024

  fun encode(frame: WireFrame): ByteArray {
    require(frame.payload.size <= maxPayloadBytes)
    val header = JSONObject()
      .put("id", frame.id)
      .put("kind", frame.kind.name)
      .put("senderID", frame.senderID)
      .put("timestamp", frame.timestamp)
      .put("metadata", JSONObject(frame.metadata))
      .put("payloadLength", frame.payload.size)
    frame.recipientID?.let { header.put("recipientID", it) }
    frame.transferID?.let { header.put("transferID", it) }

    val headerBytes = header.toString().toByteArray(Charsets.UTF_8)
    require(headerBytes.size in 1..maxHeaderBytes)

    val output = ByteArrayOutputStream()
    output.write(ByteBuffer.allocate(4).order(ByteOrder.BIG_ENDIAN).putInt(headerBytes.size).array())
    output.write(headerBytes)
    output.write(frame.payload)
    return output.toByteArray()
  }

  fun nextFrameLength(buffer: ByteArray): Int? {
    if (buffer.size < 4) return null
    val headerLength = ByteBuffer.wrap(buffer, 0, 4).order(ByteOrder.BIG_ENDIAN).int
    require(headerLength in 1..maxHeaderBytes)
    if (buffer.size < 4 + headerLength) return null
    val header = JSONObject(String(buffer, 4, headerLength, Charsets.UTF_8))
    val payloadLength = header.optInt("payloadLength", 0)
    require(payloadLength in 0..maxPayloadBytes)
    return 4 + headerLength + payloadLength
  }

  fun decode(data: ByteArray): WireFrame {
    require(data.size >= 4)
    val headerLength = ByteBuffer.wrap(data, 0, 4).order(ByteOrder.BIG_ENDIAN).int
    require(headerLength in 1..maxHeaderBytes)
    require(data.size >= 4 + headerLength)
    val header = JSONObject(String(data, 4, headerLength, Charsets.UTF_8))
    val payloadLength = header.getInt("payloadLength")
    require(payloadLength in 0..maxPayloadBytes)
    val fullLength = 4 + headerLength + payloadLength
    require(data.size >= fullLength)
    val metadataJson = header.optJSONObject("metadata") ?: JSONObject()
    val metadata = mutableMapOf<String, String>()
    metadataJson.keys().forEach { key -> metadata[key] = metadataJson.optString(key) }
    return WireFrame(
      kind = FrameKind.valueOf(header.getString("kind")),
      senderID = header.getString("senderID"),
      recipientID = header.optString("recipientID", "").takeIf { it.isNotBlank() },
      transferID = header.optString("transferID", "").takeIf { it.isNotBlank() },
      metadata = metadata,
      payload = data.copyOfRange(4 + headerLength, fullLength),
      id = header.optString("id", UUID.randomUUID().toString()),
      timestamp = header.optString("timestamp")
    )
  }
}

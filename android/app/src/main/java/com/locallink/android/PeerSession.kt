package com.locallink.android

import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.Socket
import java.util.UUID
import java.util.concurrent.ExecutorService

class PeerSession(
  private val socket: Socket,
  private val local: LocalIdentity,
  private val executor: ExecutorService,
  private val onHello: (PeerSession, DeviceIdentity) -> Unit,
  private val onFrame: (PeerSession, WireFrame, DeviceIdentity?) -> Unit,
  private val onClosed: (PeerSession) -> Unit,
  private val onError: (Throwable) -> Unit
) {
  @Volatile var remoteIdentity: DeviceIdentity? = null
    private set
  @Volatile private var crypto: SessionCrypto? = null
  @Volatile private var running = true

  fun start() {
    sendHello()
    executor.execute { readLoop() }
  }

  fun close(sendDisconnect: Boolean = false) {
    running = false
    if (sendDisconnect) send(FrameKind.disconnect)
    runCatching { socket.close() }
    onClosed(this)
  }

  fun sendHello() {
    val payload = local.identity.toJson().toString().toByteArray(Charsets.UTF_8)
    send(FrameKind.hello, payload = payload)
  }

  fun sendPairRequest(code: String) {
    send(FrameKind.pairRequest, metadata = mapOf("publicKey" to local.identity.publicKey, "code" to code))
  }

  fun sendPairAccepted(code: String) {
    send(FrameKind.pairAccepted, metadata = mapOf("code" to code))
  }

  fun sendText(text: String) {
    val payload = crypto?.seal(text.toByteArray(Charsets.UTF_8)) ?: text.toByteArray(Charsets.UTF_8)
    send(FrameKind.text, payload = payload)
  }

  fun sendError(message: String) {
    send(FrameKind.error, metadata = mapOf("message" to message))
  }

  fun sendData(data: ByteArray, fileName: String, contentType: String?) {
    val transferID = UUID.randomUUID().toString()
    val checksum = LocalLinkHashes.sha256Hex(data)
    send(
      FrameKind.fileOffer,
      transferID = transferID,
      metadata = mapOf(
        "fileName" to fileName,
        "contentType" to (contentType ?: "application/octet-stream"),
        "byteCount" to data.size.toString(),
        "checksum" to checksum
      )
    )

    var offset = 0
    val chunkSize = 256 * 1024
    while (offset < data.size) {
      val end = minOf(offset + chunkSize, data.size)
      val chunk = data.copyOfRange(offset, end)
      send(
        FrameKind.fileChunk,
        transferID = transferID,
        metadata = mapOf("offset" to offset.toString()),
        payload = crypto?.seal(chunk) ?: chunk
      )
      offset = end
    }
    send(FrameKind.fileComplete, transferID = transferID, metadata = mapOf("checksum" to checksum))
  }

  private fun send(
    kind: FrameKind,
    transferID: String? = null,
    metadata: Map<String, String> = emptyMap(),
    payload: ByteArray = ByteArray(0)
  ) {
    executor.execute {
      runCatching {
        val frame = WireFrame(
          kind = kind,
          senderID = local.identity.deviceID,
          recipientID = remoteIdentity?.deviceID,
          transferID = transferID,
          metadata = metadata,
          payload = payload
        )
        socket.getOutputStream().write(FrameCodec.encode(frame))
        socket.getOutputStream().flush()
      }.onFailure(onError)
    }
  }

  private fun readLoop() {
    val buffer = ByteArrayOutputStream()
    val scratch = ByteArray(64 * 1024)
    try {
      val input = socket.getInputStream()
      while (running) {
        val read = input.read(scratch)
        if (read <= 0) break
        buffer.write(scratch, 0, read)
        drain(buffer)
      }
    } catch (error: Throwable) {
      if (running) onError(error)
    } finally {
      running = false
      onClosed(this)
    }
  }

  private fun drain(buffer: ByteArrayOutputStream) {
    var bytes = buffer.toByteArray()
    while (true) {
      val length = FrameCodec.nextFrameLength(bytes) ?: break
      if (bytes.size < length) break
      handle(FrameCodec.decode(bytes.copyOfRange(0, length)))
      bytes = bytes.copyOfRange(length, bytes.size)
    }
    buffer.reset()
    buffer.write(bytes)
  }

  private fun handle(frame: WireFrame) {
    val clearFrame = if (frame.kind == FrameKind.text || frame.kind == FrameKind.fileChunk) {
      val opened = crypto?.open(frame.payload) ?: frame.payload
      frame.copy(payload = opened)
    } else {
      frame
    }

    if (clearFrame.kind == FrameKind.hello) {
      val identity = DeviceIdentity.fromJson(JSONObject(String(clearFrame.payload, Charsets.UTF_8)))
      remoteIdentity = identity
      crypto = runCatching { SessionCrypto(local.privateKey, identity.publicKey) }.getOrNull()
      onHello(this, identity)
    }
    onFrame(this, clearFrame, remoteIdentity)
  }
}

package com.locallink.android

import java.io.ByteArrayOutputStream

class TransferAssembler {
  private data class Pending(
    var item: TransferItem,
    val data: ByteArrayOutputStream = ByteArrayOutputStream()
  )

  private val pending = mutableMapOf<String, Pending>()

  fun acceptOffer(peerID: String, frame: WireFrame): TransferItem? {
    val id = frame.transferID ?: return null
    val item = TransferItem(
      id = id,
      peerID = peerID,
      outgoing = false,
      fileName = frame.metadata["fileName"] ?: "Received File",
      contentType = frame.metadata["contentType"],
      totalBytes = frame.metadata["byteCount"]?.toLongOrNull() ?: 0,
      checksum = frame.metadata["checksum"]
    )
    pending[id] = Pending(item)
    return item
  }

  fun appendChunk(frame: WireFrame): TransferItem? {
    val id = frame.transferID ?: return null
    val current = pending[id] ?: return null
    current.data.write(frame.payload)
    current.item = current.item.copy(completedBytes = current.data.size().toLong())
    return current.item
  }

  fun complete(frame: WireFrame): Pair<TransferItem, ByteArray>? {
    val id = frame.transferID ?: return null
    val current = pending[id] ?: return null
    val data = current.data.toByteArray()
    val expected = frame.metadata["checksum"] ?: current.item.checksum
    if (expected != null && expected != LocalLinkHashes.sha256Hex(data)) {
      pending.remove(id)
      return current.item.copy(complete = false) to ByteArray(0)
    }
    pending.remove(id)
    return current.item.copy(completedBytes = data.size.toLong(), complete = true) to data
  }
}

import Foundation

public enum TransferAssemblerError: Error, Equatable {
  case missingOffer
  case checksumMismatch(expected: String, actual: String)
}

public struct TransferAssembler {
  private struct Pending {
    var item: TransferItem
    var data = Data()
  }

  private var pending: [UUID: Pending] = [:]

  public init() {}

  public mutating func acceptOffer(peerID: String, frame: WireFrame) -> TransferItem? {
    guard frame.header.kind == .fileOffer, let transferID = frame.header.transferID else { return nil }
    let metadata = frame.header.metadata
    let item = TransferItem(
      id: transferID,
      peerID: peerID,
      direction: .incoming,
      fileName: metadata["fileName"] ?? "Received File",
      contentType: metadata["contentType"],
      totalBytes: Int64(metadata["byteCount"] ?? "0") ?? 0,
      checksum: metadata["checksum"],
      status: .inProgress
    )
    pending[transferID] = Pending(item: item)
    return item
  }

  public mutating func appendChunk(_ frame: WireFrame) throws -> TransferItem {
    guard frame.header.kind == .fileChunk, let transferID = frame.header.transferID, var current = pending[transferID] else {
      throw TransferAssemblerError.missingOffer
    }
    current.data.append(frame.payload)
    current.item.completedBytes = Int64(current.data.count)
    current.item.status = .inProgress
    pending[transferID] = current
    return current.item
  }

  public mutating func complete(_ frame: WireFrame) throws -> (TransferItem, Data) {
    guard frame.header.kind == .fileComplete, let transferID = frame.header.transferID, var current = pending[transferID] else {
      throw TransferAssemblerError.missingOffer
    }

    let actual = Checksum.sha256Hex(for: current.data)
    let expected = frame.header.metadata["checksum"] ?? current.item.checksum
    if let expected, expected != actual {
      current.item.status = .failed
      current.item.errorMessage = "Checksum mismatch"
      pending[transferID] = current
      throw TransferAssemblerError.checksumMismatch(expected: expected, actual: actual)
    }

    current.item.status = .complete
    current.item.completedBytes = Int64(current.data.count)
    pending.removeValue(forKey: transferID)
    return (current.item, current.data)
  }
}

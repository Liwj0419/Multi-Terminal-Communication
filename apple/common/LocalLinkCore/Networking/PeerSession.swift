import Foundation
import Network

public enum PeerSessionError: Error {
  case missingRemoteIdentity
  case untrustedPeer
  case invalidPayload
}

public final class PeerSession: @unchecked Sendable, Identifiable {
  public let id = UUID()
  public let connection: NWConnection
  public let endpointDescription: String

  private let local: LocalDeviceIdentity
  private let queue: DispatchQueue
  private var receiveBuffer = Data()
  private var sessionCrypto: SessionCrypto?
  private var stateChangeHandlers: [@Sendable (NWConnection.State) -> Void] = []

  public private(set) var remoteIdentity: DeviceIdentity?
  public var onRemoteIdentity: (@Sendable (DeviceIdentity) -> Void)?
  public var onFrame: (@Sendable (WireFrame, DeviceIdentity?) -> Void)?
  public var onStateChange: (@Sendable (NWConnection.State) -> Void)?
  public var onError: (@Sendable (Error) -> Void)?

  public init(
    connection: NWConnection,
    local: LocalDeviceIdentity,
    queue: DispatchQueue = DispatchQueue(label: "LocalLink.PeerSession")
  ) {
    self.connection = connection
    self.local = local
    self.queue = queue
    self.endpointDescription = String(describing: connection.endpoint)
  }

  public func start() {
    connection.stateUpdateHandler = { [weak self] state in
      self?.onStateChange?(state)
      self?.stateChangeHandlers.forEach { $0(state) }
      if case .ready = state {
        self?.sendHello()
        self?.receiveNext()
      }
    }
    connection.start(queue: queue)
  }

  public func cancel() {
    connection.cancel()
  }

  public func addStateChangeHandler(_ handler: @escaping @Sendable (NWConnection.State) -> Void) {
    stateChangeHandlers.append(handler)
  }

  public func sendHello() {
    do {
      let payload = try JSONEncoder.localLink.encode(local.identity)
      try send(kind: .hello, payload: payload)
    } catch {
      onError?(error)
    }
  }

  public func sendPairRequest(code: String? = nil) {
    do {
      var metadata = ["publicKey": local.identity.publicKey]
      if let code {
        metadata["code"] = code
      }
      try send(kind: .pairRequest, metadata: metadata)
    } catch {
      onError?(error)
    }
  }

  public func sendPairConfirm(code: String) {
    do {
      try send(kind: .pairConfirm, metadata: ["code": code])
    } catch {
      onError?(error)
    }
  }

  public func sendPairAccepted(code: String) {
    do {
      try send(kind: .pairAccepted, metadata: ["code": code])
    } catch {
      onError?(error)
    }
  }

  public func sendAuth() {
    do {
      try send(kind: .auth, metadata: ["deviceID": local.identity.deviceID])
    } catch {
      onError?(error)
    }
  }

  public func sendError(_ message: String) {
    do {
      try send(kind: .error, metadata: ["message": message])
    } catch {
      onError?(error)
    }
  }

  public func sendDisconnect() {
    do {
      try send(kind: .disconnect)
    } catch {
      onError?(error)
    }
  }

  public func sendText(_ text: String) {
    do {
      let payload = Data(text.utf8)
      let encryptedPayload = try encryptedIfPossible(payload)
      try send(kind: .text, payload: encryptedPayload)
    } catch {
      onError?(error)
    }
  }

  public func sendFile(url: URL, contentType: String? = nil, chunkSize: Int = 256 * 1024) {
    do {
      let data = try Data(contentsOf: url)
      try sendData(data, fileName: url.lastPathComponent, contentType: contentType, chunkSize: chunkSize)
    } catch {
      onError?(error)
    }
  }

  public func sendData(
    _ data: Data,
    fileName: String,
    contentType: String? = nil,
    chunkSize: Int = 256 * 1024
  ) throws {
    let transferID = UUID()
    let checksum = Checksum.sha256Hex(for: data)
    try send(
      kind: .fileOffer,
      transferID: transferID,
      metadata: [
        "fileName": fileName,
        "contentType": contentType ?? "application/octet-stream",
        "byteCount": String(data.count),
        "checksum": checksum
      ]
    )

    var offset = 0
    while offset < data.count {
      let end = min(offset + chunkSize, data.count)
      let chunk = data.subdata(in: offset..<end)
      try send(
        kind: .fileChunk,
        transferID: transferID,
        metadata: ["offset": String(offset)],
        payload: try encryptedIfPossible(chunk)
      )
      offset = end
    }

    try send(kind: .fileComplete, transferID: transferID, metadata: ["checksum": checksum])
  }

  private func send(
    kind: FrameKind,
    transferID: UUID? = nil,
    metadata: [String: String] = [:],
    payload: Data = Data()
  ) throws {
    let header = FrameHeader(
      kind: kind,
      senderID: local.identity.deviceID,
      recipientID: remoteIdentity?.deviceID,
      transferID: transferID,
      metadata: metadata
    )
    let frame = WireFrame(header: header, payload: payload)
    let data = try FrameCodec.encode(frame)
    connection.send(content: data, completion: .contentProcessed { [weak self] error in
      if let error {
        self?.onError?(error)
      }
    })
  }

  private func receiveNext() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 512 * 1024) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      if let data, !data.isEmpty {
        self.receiveBuffer.append(data)
        self.drainFrames()
      }
      if let error {
        self.onError?(error)
        return
      }
      if !isComplete {
        self.receiveNext()
      }
    }
  }

  private func drainFrames() {
    do {
      while let frameLength = try FrameCodec.nextFrameLength(in: receiveBuffer), receiveBuffer.count >= frameLength {
        let frameData = receiveBuffer.prefix(frameLength)
        receiveBuffer = Data(receiveBuffer.dropFirst(frameLength))
        do {
          let frame = try FrameCodec.decode(Data(frameData))
          handle(frame)
        } catch {
          onError?(error)
        }
      }
    } catch {
      receiveBuffer.removeAll(keepingCapacity: false)
      onError?(error)
      cancel()
    }
  }

  private func handle(_ frame: WireFrame) {
    if frame.header.kind == .hello {
      do {
        let identity = try JSONDecoder.localLink.decode(DeviceIdentity.self, from: frame.payload)
        remoteIdentity = identity
        sessionCrypto = try? SessionCrypto(
          localPrivateKeyData: local.privateKeyData,
          remotePublicKeyBase64: identity.publicKey
        )
        onRemoteIdentity?(identity)
      } catch {
        onError?(error)
      }
    }
    onFrame?(decryptedIfPossible(frame), remoteIdentity)
  }

  private func encryptedIfPossible(_ payload: Data) throws -> Data {
    guard let sessionCrypto else { return payload }
    return try sessionCrypto.seal(payload)
  }

  private func decryptedIfPossible(_ frame: WireFrame) -> WireFrame {
    guard [.text, .fileChunk].contains(frame.header.kind), let sessionCrypto else { return frame }
    do {
      return WireFrame(header: frame.header, payload: try sessionCrypto.open(frame.payload))
    } catch {
      onError?(error)
      return frame
    }
  }
}

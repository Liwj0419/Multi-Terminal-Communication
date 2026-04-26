import Foundation
import LocalLinkCore

@discardableResult
func expect(_ condition: @autoclosure () -> Bool, _ message: String) -> Bool {
  if !condition() {
    fatalError("Smoke test failed: \(message)")
  }
  return true
}

func testFrameCodec() throws {
  let payload = Data([0, 1, 2, 3, 255])
  let header = FrameHeader(
    kind: .fileChunk,
    senderID: "sender",
    recipientID: "recipient",
    transferID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"),
    metadata: ["offset": "0"]
  )
  let decoded = try FrameCodec.decode(try FrameCodec.encode(WireFrame(header: header, payload: payload)))

  expect(decoded.header.kind == .fileChunk, "frame kind should round-trip")
  expect(decoded.header.senderID == "sender", "sender should round-trip")
  expect(decoded.header.payloadLength == payload.count, "payload length should match")
  expect(decoded.payload == payload, "payload should round-trip")

  let encodedText = try FrameCodec.encode(
    WireFrame(header: FrameHeader(kind: .text, senderID: "sender"), payload: Data("hello".utf8))
  )
  do {
    _ = try FrameCodec.decode(Data(encodedText.dropLast(2)))
    fatalError("Smoke test failed: incomplete frame should throw")
  } catch {
    // Expected.
  }

  let invalidHeaderLength = Data([0, 0, 0, 0])
  do {
    _ = try FrameCodec.nextFrameLength(in: invalidHeaderLength)
    fatalError("Smoke test failed: zero header length should throw")
  } catch FrameCodecError.invalidHeaderLength(0) {
    // Expected.
  }

  let shortPrefix = try FrameCodec.nextFrameLength(in: Data([0, 0, 0]))
  expect(shortPrefix == nil, "short prefixes should be treated as incomplete data")

  var prefixedFrame = Data([255])
  prefixedFrame.append(encodedText)
  let nonZeroStartIndexFrame = Data(prefixedFrame.dropFirst())
  let nonZeroStartIndexFrameLength = try FrameCodec.nextFrameLength(in: nonZeroStartIndexFrame)
  expect(nonZeroStartIndexFrameLength == encodedText.count, "non-zero startIndex frames should parse")

  var combinedFrames = encodedText
  combinedFrames.append(encodedText)
  let firstFrameLength = try FrameCodec.nextFrameLength(in: combinedFrames)
  expect(firstFrameLength == encodedText.count, "first frame length should parse")
  let secondFrameBuffer = Data(combinedFrames.dropFirst(firstFrameLength ?? 0))
  let secondFrameLength = try FrameCodec.nextFrameLength(in: secondFrameBuffer)
  expect(secondFrameLength == encodedText.count, "second frame after dropFirst should parse")

  let oversizedHeaderLength = UInt32(FrameCodec.maxHeaderBytes + 1).bigEndian
  let oversizedHeader = withUnsafeBytes(of: oversizedHeaderLength) { Data($0) }
  do {
    _ = try FrameCodec.nextFrameLength(in: oversizedHeader)
    fatalError("Smoke test failed: oversized header should throw")
  } catch FrameCodecError.headerTooLarge {
    // Expected.
  }
}

func testPairingAndCrypto() throws {
  let alice = KeyPairFactory.makeIdentity(displayName: "Alice", platform: .macOS)
  let bob = KeyPairFactory.makeIdentity(displayName: "Bob", platform: .iOS)

  let first = PairingCode.derive(localPublicKey: alice.identity.publicKey, remotePublicKey: bob.identity.publicKey)
  let second = PairingCode.derive(localPublicKey: bob.identity.publicKey, remotePublicKey: alice.identity.publicKey)
  expect(first == second, "pairing code should be symmetric")
  expect(first.count == 6, "pairing code should be six digits")
  expect(Int(first) != nil, "pairing code should be numeric")

  let aliceCrypto = try SessionCrypto(
    localPrivateKeyData: alice.privateKeyData,
    remotePublicKeyBase64: bob.identity.publicKey
  )
  let bobCrypto = try SessionCrypto(
    localPrivateKeyData: bob.privateKeyData,
    remotePublicKeyBase64: alice.identity.publicKey
  )
  let opened = try bobCrypto.open(try aliceCrypto.seal(Data("secret".utf8)))
  expect(String(decoding: opened, as: UTF8.self) == "secret", "paired crypto should decrypt")
}

func testTrustedPeers() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let store = JSONTrustedPeerStore(fileURL: directory.appendingPathComponent("trusted.json"))
  let peer = TrustedPeer(deviceID: "peer-1", displayName: "Peer", platform: .iOS, publicKey: "public")

  try store.saveTrustedPeer(peer)
  let isTrusted = try store.isTrusted(deviceID: "peer-1", publicKey: "public")
  let isChangedKeyTrusted = try store.isTrusted(deviceID: "peer-1", publicKey: "changed")
  expect(isTrusted, "peer should be trusted")
  expect(!isChangedKeyTrusted, "changed key should not be trusted")
  try store.forgetTrustedPeer(deviceID: "peer-1")
  let peers = try store.loadTrustedPeers()
  expect(peers.isEmpty, "peer should be forgotten")
}

func testConversationMessageStore() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let store = JSONConversationMessageStore(fileURL: directory.appendingPathComponent("messages.json"))
  let first = ConversationMessage(peerID: "peer-1", isOutgoing: true, text: "hello")
  let second = ConversationMessage(peerID: "peer-2", isOutgoing: false, text: "world")

  try store.saveMessages([first, second])
  let saved = try store.loadMessages()
  expect(saved.count == 2, "messages should persist")
  try store.clearMessages(peerID: "peer-1")
  let remaining = try store.loadMessages()
  expect(remaining.count == 1, "peer messages should clear")
  expect(remaining.first?.peerID == "peer-2", "other peer messages should remain")
}

func testTransferItemStore() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let store = JSONTransferItemStore(fileURL: directory.appendingPathComponent("transfers.json"))
  let picture = TransferItem(
    peerID: "peer-1",
    direction: .incoming,
    fileName: "photo.jpg",
    contentType: "image/jpeg",
    totalBytes: 10,
    status: .complete,
    localPath: "/tmp/photo.jpg"
  )
  let file = TransferItem(peerID: "peer-2", direction: .outgoing, fileName: "note.txt", totalBytes: 5)

  expect(picture.isPicture, "image transfer should be categorized as picture")
  expect(!file.isPicture, "non-image transfer should be categorized as file")
  try store.saveTransfers([picture, file])
  let saved = try store.loadTransfers()
  expect(saved.count == 2, "transfers should persist")
  try store.clearTransfers(peerID: "peer-1")
  let remaining = try store.loadTransfers()
  expect(remaining.count == 1, "peer transfers should clear")
  expect(remaining.first?.peerID == "peer-2", "other peer transfers should remain")
}

func testTransferAssembler() throws {
  var assembler = TransferAssembler()
  let transferID = UUID()
  let data = Data("hello file".utf8)
  let checksum = Checksum.sha256Hex(for: data)

  let offer = WireFrame(
    header: FrameHeader(
      kind: .fileOffer,
      senderID: "peer",
      transferID: transferID,
      metadata: [
        "fileName": "hello.txt",
        "byteCount": String(data.count),
        "checksum": checksum
      ]
    )
  )
  let chunk = WireFrame(
    header: FrameHeader(kind: .fileChunk, senderID: "peer", transferID: transferID),
    payload: data
  )
  let complete = WireFrame(
    header: FrameHeader(
      kind: .fileComplete,
      senderID: "peer",
      transferID: transferID,
      metadata: ["checksum": checksum]
    )
  )

  expect(assembler.acceptOffer(peerID: "peer", frame: offer)?.fileName == "hello.txt", "offer should be accepted")
  let progress = try assembler.appendChunk(chunk)
  expect(progress.completedBytes == Int64(data.count), "chunk should update progress")
  let finished = try assembler.complete(complete)
  expect(finished.0.status == .complete, "transfer should complete")
  expect(finished.1 == data, "assembled data should match")

  var mismatchAssembler = TransferAssembler()
  _ = mismatchAssembler.acceptOffer(
    peerID: "peer",
    frame: WireFrame(
      header: FrameHeader(
        kind: .fileOffer,
        senderID: "peer",
        transferID: transferID,
        metadata: ["fileName": "bad.txt", "byteCount": String(data.count), "checksum": "bad"]
      )
    )
  )
  _ = try mismatchAssembler.appendChunk(chunk)
  do {
    _ = try mismatchAssembler.complete(WireFrame(header: FrameHeader(kind: .fileComplete, senderID: "peer", transferID: transferID)))
    fatalError("Smoke test failed: checksum mismatch should throw")
  } catch {
    // Expected.
  }
}

try testFrameCodec()
try testPairingAndCrypto()
try testTrustedPeers()
try testConversationMessageStore()
try testTransferItemStore()
try testTransferAssembler()

print("LocalLinkCore smoke tests passed")

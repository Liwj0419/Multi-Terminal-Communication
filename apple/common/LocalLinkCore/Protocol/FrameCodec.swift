import Foundation

public enum FrameKind: String, Codable, CaseIterable, Sendable {
  case hello
  case pairRequest
  case pairConfirm
  case pairAccepted
  case auth
  case text
  case fileOffer
  case fileChunk
  case fileComplete
  case cancel
  case disconnect
  case error
}

public struct FrameHeader: Codable, Equatable, Sendable {
  public var id: UUID
  public var kind: FrameKind
  public var senderID: String
  public var recipientID: String?
  public var transferID: UUID?
  public var timestamp: Date
  public var metadata: [String: String]
  public var payloadLength: Int

  public init(
    id: UUID = UUID(),
    kind: FrameKind,
    senderID: String,
    recipientID: String? = nil,
    transferID: UUID? = nil,
    timestamp: Date = Date(),
    metadata: [String: String] = [:],
    payloadLength: Int = 0
  ) {
    self.id = id
    self.kind = kind
    self.senderID = senderID
    self.recipientID = recipientID
    self.transferID = transferID
    self.timestamp = timestamp
    self.metadata = metadata
    self.payloadLength = payloadLength
  }
}

public struct WireFrame: Equatable, Sendable {
  public var header: FrameHeader
  public var payload: Data

  public init(header: FrameHeader, payload: Data = Data()) {
    var header = header
    header.payloadLength = payload.count
    self.header = header
    self.payload = payload
  }
}

public enum FrameCodecError: Error, Equatable {
  case frameTooSmall
  case headerTooLarge
  case payloadTooLarge
  case invalidHeaderLength(Int)
  case invalidPayloadLength(Int)
  case invalidFrameLength(Int)
  case incompleteFrame(expected: Int, actual: Int)
  case payloadLengthMismatch(expected: Int, actual: Int)
}

public enum FrameCodec {
  public static let maxHeaderBytes = 64 * 1024
  public static let maxPayloadBytes = 8 * 1024 * 1024

  public static func encode(_ frame: WireFrame, encoder: JSONEncoder = .localLink) throws -> Data {
    let headerData = try encoder.encode(frame.header)
    guard headerData.count <= maxHeaderBytes else { throw FrameCodecError.headerTooLarge }
    guard frame.payload.count <= maxPayloadBytes else { throw FrameCodecError.payloadTooLarge }

    var output = Data()
    output.appendUInt32(UInt32(headerData.count))
    output.append(headerData)
    output.append(frame.payload)
    return output
  }

  public static func decode(_ data: Data, decoder: JSONDecoder = .localLink) throws -> WireFrame {
    let data = Data(data)
    guard data.count >= 4 else { throw FrameCodecError.frameTooSmall }

    guard let headerLengthValue = data.readUInt32(at: 0) else {
      throw FrameCodecError.frameTooSmall
    }
    let headerLength = Int(headerLengthValue)
    guard headerLength > 0 else { throw FrameCodecError.invalidHeaderLength(headerLength) }
    guard headerLength <= maxHeaderBytes else { throw FrameCodecError.headerTooLarge }

    let expectedLength = 4 + headerLength
    guard data.count >= expectedLength else {
      throw FrameCodecError.incompleteFrame(expected: expectedLength, actual: data.count)
    }

    guard let headerData = data.safeSubdata(in: 4..<(4 + headerLength)) else {
      throw FrameCodecError.incompleteFrame(expected: expectedLength, actual: data.count)
    }
    let header = try decoder.decode(FrameHeader.self, from: headerData)
    guard header.payloadLength >= 0 else { throw FrameCodecError.invalidPayloadLength(header.payloadLength) }
    guard header.payloadLength <= maxPayloadBytes else { throw FrameCodecError.payloadTooLarge }

    let fullLength = 4 + headerLength + header.payloadLength
    guard data.count >= fullLength else {
      throw FrameCodecError.incompleteFrame(expected: fullLength, actual: data.count)
    }

    guard let payload = data.safeSubdata(in: (4 + headerLength)..<fullLength) else {
      throw FrameCodecError.incompleteFrame(expected: fullLength, actual: data.count)
    }
    guard payload.count == header.payloadLength else {
      throw FrameCodecError.payloadLengthMismatch(expected: header.payloadLength, actual: payload.count)
    }

    return WireFrame(header: header, payload: payload)
  }

  public static func nextFrameLength(in buffer: Data) throws -> Int? {
    let buffer = Data(buffer)
    guard buffer.count >= 4 else { return nil }
    guard let headerLengthValue = buffer.readUInt32(at: 0) else { return nil }
    let headerLength = Int(headerLengthValue)
    guard headerLength > 0 else { throw FrameCodecError.invalidHeaderLength(headerLength) }
    guard headerLength <= maxHeaderBytes else { throw FrameCodecError.headerTooLarge }
    guard buffer.count >= 4 + headerLength else { return nil }
    guard let headerData = buffer.safeSubdata(in: 4..<(4 + headerLength)) else { return nil }
    guard let header = try? JSONDecoder.localLink.decode(
      FrameHeader.self,
      from: headerData
    ) else {
      return nil
    }
    guard header.payloadLength >= 0 else { throw FrameCodecError.invalidPayloadLength(header.payloadLength) }
    guard header.payloadLength <= maxPayloadBytes else { throw FrameCodecError.payloadTooLarge }

    let frameLength = 4 + headerLength + header.payloadLength
    guard frameLength >= 4 + headerLength else {
      throw FrameCodecError.invalidFrameLength(frameLength)
    }
    return frameLength
  }
}

extension Data {
  mutating func appendUInt32(_ value: UInt32) {
    var bigEndian = value.bigEndian
    Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
  }

  func readUInt32(at offset: Int) -> UInt32? {
    guard offset >= 0, count >= offset + 4 else { return nil }
    let lowerBound = index(startIndex, offsetBy: offset)
    let upperBound = index(lowerBound, offsetBy: 4)
    guard upperBound <= endIndex else { return nil }
    let slice = self[lowerBound..<upperBound]
    return slice.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
  }

  func safeSubdata(in range: Range<Int>) -> Data? {
    guard range.lowerBound >= 0, range.upperBound >= range.lowerBound else { return nil }
    guard count >= range.upperBound else { return nil }
    let lowerBound = index(startIndex, offsetBy: range.lowerBound)
    let upperBound = index(startIndex, offsetBy: range.upperBound)
    guard lowerBound <= upperBound, upperBound <= endIndex else { return nil }
    return subdata(in: lowerBound..<upperBound)
  }
}

extension JSONEncoder {
  public static var localLink: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }
}

extension JSONDecoder {
  public static var localLink: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}

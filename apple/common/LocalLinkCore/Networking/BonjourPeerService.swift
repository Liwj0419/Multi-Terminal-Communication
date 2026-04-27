import Foundation
import Darwin
import Network

public final class BonjourPeerService: @unchecked Sendable {
  public static let serviceType = "_locallink._tcp"
  private static let preferredPort: NWEndpoint.Port = 53317

  private let local: LocalDeviceIdentity
  private let trustedStore: TrustedPeerStoring
  private let queue = DispatchQueue(label: "LocalLink.BonjourPeerService")

  private var listener: NWListener?
  private var browser: NWBrowser?
  private var sessions: [UUID: PeerSession] = [:]
  private var listenPort: UInt16?

  public var onDiscoveredPeersChanged: (@Sendable ([DiscoveredPeer]) -> Void)?
  public var onSession: (@Sendable (PeerSession) -> Void)?
  public var onError: (@Sendable (Error) -> Void)?
  public var connectionAddresses: [String] {
    guard let listenPort else { return [] }
    return Self.localIPv4Addresses().map { "\($0):\(listenPort)" }
  }

  public init(local: LocalDeviceIdentity, trustedStore: TrustedPeerStoring) {
    self.local = local
    self.trustedStore = trustedStore
  }

  public func start() throws {
    try startListening()
    startBrowsing()
  }

  public func stop() {
    listener?.cancel()
    browser?.cancel()
    sessions.values.forEach { $0.cancel() }
    sessions.removeAll()
  }

  @discardableResult
  public func connect(to peer: DiscoveredPeer) -> PeerSession? {
    guard let endpoint = peer.endpoint else { return nil }
    let session = PeerSession(connection: NWConnection(to: endpoint, using: .tcp), local: local, listenPort: listenPort)
    install(session)
    session.start()
    return session
  }

  private func startListening() throws {
    let listener = (try? NWListener(using: .tcp, on: Self.preferredPort)) ?? (try NWListener(using: .tcp))
    var txt: [String: String] = [
      "id": local.identity.deviceID,
      "name": local.identity.displayName,
      "platform": local.identity.platform.rawValue,
      "version": String(local.identity.protocolVersion),
      "publicKey": local.identity.publicKey
    ]
    if let host = Self.localIPv4Addresses().first {
      txt["host"] = host
    }
    if let port = listener.port {
      listenPort = port.rawValue
      txt["port"] = String(port.rawValue)
    }
    let txtRecord = NWTXTRecord(txt)
    let shortID = String(local.identity.deviceID.prefix(8))
    listener.service = NWListener.Service(
      name: "\(local.identity.displayName)-\(shortID)",
      type: Self.serviceType,
      txtRecord: txtRecord
    )
    listener.newConnectionHandler = { [weak self] connection in
      guard let self else { return }
      let session = PeerSession(connection: connection, local: self.local, listenPort: self.listenPort)
      self.install(session)
      session.start()
    }
    listener.stateUpdateHandler = { [weak self] state in
      if case let .failed(error) = state {
        self?.onError?(error)
      }
    }
    listener.start(queue: queue)
    self.listener = listener
  }

  private func startBrowsing() {
    let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: .tcp)
    browser.browseResultsChangedHandler = { [weak self] results, _ in
      self?.publish(results: results)
    }
    browser.stateUpdateHandler = { [weak self] state in
      if case let .failed(error) = state {
        self?.onError?(error)
      }
    }
    browser.start(queue: queue)
    self.browser = browser
  }

  private func publish(results: Set<NWBrowser.Result>) {
    var peersByID: [String: DiscoveredPeer] = [:]

    for result in results {
      guard !isLocal(endpoint: result.endpoint) else { continue }
      let identity = identity(for: result)
      let trusted = (try? trustedStore.isTrusted(
        deviceID: identity.deviceID,
        publicKey: identity.publicKey
      )) ?? false
      let txtRecord = result.metadata.txtRecord ?? [:]
      let endpoint = Self.directEndpoint(from: txtRecord) ?? result.endpoint
      let endpointDescription = Self.directEndpointDescription(from: txtRecord) ?? String(describing: result.endpoint)
      let peer = DiscoveredPeer(
        identity: identity,
        endpoint: endpoint,
        endpointDescription: endpointDescription,
        isTrusted: trusted
      )
      peersByID[identity.deviceID] = peer
    }
    onDiscoveredPeersChanged?(Array(peersByID.values))
  }

  private func install(_ session: PeerSession) {
    sessions[session.id] = session
    session.addStateChangeHandler { [weak self, id = session.id] state in
      if case .cancelled = state {
        self?.sessions.removeValue(forKey: id)
      }
    }
    onSession?(session)
  }

  private func identity(for result: NWBrowser.Result) -> DeviceIdentity {
    if let txtRecord = result.metadata.txtRecord,
       let deviceID = txtRecord["id"],
       let displayName = txtRecord["name"],
       let platformRaw = txtRecord["platform"],
       let publicKey = txtRecord["publicKey"] {
      return DeviceIdentity(
        deviceID: deviceID,
        displayName: displayName,
        platform: DevicePlatform(rawValue: platformRaw) ?? .unknown,
        publicKey: publicKey,
        protocolVersion: Int(txtRecord["version"] ?? "") ?? 1
      )
    }
    return placeholderIdentity(for: result.endpoint)
  }

  private func placeholderIdentity(for endpoint: NWEndpoint) -> DeviceIdentity {
    let name: String
    switch endpoint {
    case let .service(serviceName, _, _, _):
      name = serviceName
    default:
      name = String(describing: endpoint)
    }

    return DeviceIdentity(
      deviceID: "endpoint:\(name)",
      displayName: name,
      platform: .unknown,
      publicKey: ""
    )
  }

  private func isLocal(endpoint: NWEndpoint) -> Bool {
    String(describing: endpoint).contains(local.identity.deviceID.prefix(8))
  }

  private static func directEndpoint(from txtRecord: [String: String]) -> NWEndpoint? {
    guard
      let host = txtRecord["host"],
      let portText = txtRecord["port"],
      let portValue = UInt16(portText),
      let port = NWEndpoint.Port(rawValue: portValue)
    else {
      return nil
    }
    return .hostPort(host: NWEndpoint.Host(host), port: port)
  }

  private static func directEndpointDescription(from txtRecord: [String: String]) -> String? {
    guard let host = txtRecord["host"], let port = txtRecord["port"] else { return nil }
    return "\(host):\(port)"
  }

  private static func localIPv4Addresses() -> [String] {
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
    defer { freeifaddrs(interfaces) }

    var addresses: [String] = []
    var pointer: UnsafeMutablePointer<ifaddrs>? = first
    while let current = pointer {
      defer { pointer = current.pointee.ifa_next }
      let flags = Int32(current.pointee.ifa_flags)
      guard
        flags & IFF_UP != 0,
        flags & IFF_LOOPBACK == 0,
        let address = current.pointee.ifa_addr,
        address.pointee.sa_family == UInt8(AF_INET)
      else {
        continue
      }

      var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      let result = getnameinfo(
        address,
        socklen_t(address.pointee.sa_len),
        &hostname,
        socklen_t(hostname.count),
        nil,
        0,
        NI_NUMERICHOST
      )
      if result == 0 {
        addresses.append(String(cString: hostname))
      }
    }
    return addresses
  }
}

private extension NWBrowser.Result.Metadata {
  var txtRecord: [String: String]? {
    if case let .bonjour(record) = self {
      return Dictionary(uniqueKeysWithValues: record.map { key, value in
        let string: String
        switch value {
        case let .string(entry):
          string = entry
        case let .data(entry):
          string = String(decoding: entry, as: UTF8.self)
        case .empty:
          string = ""
        case .none:
          string = ""
        @unknown default:
          string = ""
        }
        return (key, string)
      })
    }
    return nil
  }
}

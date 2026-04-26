import Foundation
import Network

public final class BonjourPeerService: @unchecked Sendable {
  public static let serviceType = "_locallink._tcp"

  private let local: LocalDeviceIdentity
  private let trustedStore: TrustedPeerStoring
  private let queue = DispatchQueue(label: "LocalLink.BonjourPeerService")

  private var listener: NWListener?
  private var browser: NWBrowser?
  private var sessions: [UUID: PeerSession] = [:]

  public var onDiscoveredPeersChanged: (@Sendable ([DiscoveredPeer]) -> Void)?
  public var onSession: (@Sendable (PeerSession) -> Void)?
  public var onError: (@Sendable (Error) -> Void)?

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
    let session = PeerSession(connection: NWConnection(to: endpoint, using: .tcp), local: local)
    install(session)
    session.start()
    return session
  }

  private func startListening() throws {
    let listener = try NWListener(using: .tcp)
    let txtRecord = NWTXTRecord([
      "id": local.identity.deviceID,
      "name": local.identity.displayName,
      "platform": local.identity.platform.rawValue,
      "version": String(local.identity.protocolVersion),
      "publicKey": local.identity.publicKey
    ])
    let shortID = String(local.identity.deviceID.prefix(8))
    listener.service = NWListener.Service(
      name: "\(local.identity.displayName)-\(shortID)",
      type: Self.serviceType,
      txtRecord: txtRecord
    )
    listener.newConnectionHandler = { [weak self] connection in
      guard let self else { return }
      let session = PeerSession(connection: connection, local: self.local)
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
      let peer = DiscoveredPeer(
        identity: identity,
        endpoint: result.endpoint,
        endpointDescription: String(describing: result.endpoint),
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

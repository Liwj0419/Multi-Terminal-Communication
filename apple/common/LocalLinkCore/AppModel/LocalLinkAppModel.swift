import Foundation
import Network
import Observation

public struct PairingPrompt: Identifiable, Equatable {
  public var id: String { identity.deviceID }
  public var identity: DeviceIdentity
  public var code: String

  public init(identity: DeviceIdentity, code: String) {
    self.identity = identity
    self.code = code
  }
}

@MainActor
@Observable
public final class LocalLinkAppModel {
  public private(set) var localIdentity: DeviceIdentity?
  public private(set) var trustedPeers: [TrustedPeer] = []
  public private(set) var discoveredPeers: [DiscoveredPeer] = []
  public private(set) var connectedPeerIDs: Set<String> = []
  public private(set) var messages: [ConversationMessage] = []
  public private(set) var transfers: [TransferItem] = []
  public var selectedPeerID: String?
  public var pairingPrompt: PairingPrompt?
  public var lastErrorMessage: String?
  public private(set) var isRunning = false
  public private(set) var connectionAddresses: [String] = []

  @ObservationIgnored private let identityStore: DeviceIdentityStoring
  @ObservationIgnored private let trustedStore: TrustedPeerStoring
  @ObservationIgnored private let messageStore: ConversationMessageStoring
  @ObservationIgnored private let transferStore: TransferItemStoring
  @ObservationIgnored private var local: LocalDeviceIdentity?
  @ObservationIgnored private var service: BonjourPeerService?
  @ObservationIgnored private var sessionsByPeerID: [String: PeerSession] = [:]
  @ObservationIgnored private var pendingPairingCodes: [String: String] = [:]
  @ObservationIgnored private var pendingPairRequests: Set<String> = []
  @ObservationIgnored private var transferAssembler = TransferAssembler()
  @ObservationIgnored private var transferPayloads: [UUID: Data] = [:]

  public init(
    identityStore: DeviceIdentityStoring = KeychainDeviceIdentityStore(),
    trustedStore: TrustedPeerStoring = JSONTrustedPeerStore(),
    messageStore: ConversationMessageStoring = JSONConversationMessageStore(),
    transferStore: TransferItemStoring = JSONTransferItemStore()
  ) {
    self.identityStore = identityStore
    self.trustedStore = trustedStore
    self.messageStore = messageStore
    self.transferStore = transferStore
  }

  public func start() {
    do {
      let local = try identityStore.loadOrCreate(
        displayName: Self.defaultDeviceName(),
        platform: .currentApplePlatform
      )
      self.local = local
      localIdentity = local.identity
      trustedPeers = try trustedStore.loadTrustedPeers()
      messages = try messageStore.loadMessages()
      transfers = try transferStore.loadTransfers().filter { $0.downloadedPath != nil }
      persistTransfers()

      let service = BonjourPeerService(local: local, trustedStore: trustedStore)
      service.onDiscoveredPeersChanged = { [weak self] peers in
        Task { @MainActor in self?.mergeDiscovered(peers) }
      }
      service.onSession = { [weak self] session in
        Task { @MainActor in self?.install(session) }
      }
      service.onError = { [weak self] error in
        Task { @MainActor in self?.lastErrorMessage = error.localizedDescription }
      }
      service.onConnectionAddressesChanged = { [weak self] addresses in
        Task { @MainActor in self?.connectionAddresses = addresses }
      }
      try service.start()
      self.service = service
      connectionAddresses = service.connectionAddresses
      isRunning = true
    } catch {
      lastErrorMessage = error.localizedDescription
    }
  }

  public func stop() {
    clearAllEphemeralTransfers()
    service?.stop()
    service = nil
    connectionAddresses = []
    sessionsByPeerID.removeAll()
    connectedPeerIDs.removeAll()
    isRunning = false
  }

  public func updateDeviceName(_ name: String) {
    do {
      let updated = try identityStore.updateDisplayName(name)
      local = updated
      localIdentity = updated.identity
      stop()
      start()
    } catch {
      lastErrorMessage = error.localizedDescription
    }
  }

  public func pair(with peer: DiscoveredPeer) {
    let peer = resolvedPeer(peer)
    if isTrusted(peer.identity) {
      connect(to: peer)
      return
    }
    if let session = session(for: peer), session.remoteIdentity != nil {
      let code = pairingCode(for: peer.identity)
      pendingPairingCodes[peer.identity.deviceID] = code
      session.sendPairRequest(code: code)
    } else {
      pendingPairRequests.insert(peer.identity.deviceID)
    }
  }

  public func confirmPairing(with identity: DeviceIdentity) {
    let code = pendingPairingCodes[identity.deviceID] ?? pairingCode(for: identity)
    completePairing(with: identity)
    sessionsByPeerID[identity.deviceID]?.sendPairAccepted(code: code)
  }

  private func completePairing(with identity: DeviceIdentity) {
    do {
      let endpoint = discoveredPeers.first { $0.identity.deviceID == identity.deviceID }?.endpoint
      let (host, port) = hostPort(from: endpoint)
      let peer = trustedPeer(identity: identity, lastHost: host, lastPort: port)
      try trustedStore.saveTrustedPeer(peer)
      trustedPeers = try trustedStore.loadTrustedPeers()
      discoveredPeers = discoveredPeers.map { discovered in
        var copy = discovered
        if copy.identity.deviceID == identity.deviceID {
          copy.isTrusted = true
        }
        return copy
      }
      if sessionsByPeerID[identity.deviceID] != nil {
        connectedPeerIDs.insert(identity.deviceID)
      }
      pendingPairingCodes.removeValue(forKey: identity.deviceID)
      pendingPairRequests.remove(identity.deviceID)
      pairingPrompt = nil
    } catch {
      lastErrorMessage = error.localizedDescription
    }
  }

  public func forget(peerID: String) {
    do {
      try trustedStore.forgetTrustedPeer(deviceID: peerID)
      trustedPeers = try trustedStore.loadTrustedPeers()
      disconnect(peerID: peerID)
      discoveredPeers = discoveredPeers.map { discovered in
        var copy = discovered
        if copy.identity.deviceID == peerID {
          copy.isTrusted = false
        }
        return copy
      }
    } catch {
      lastErrorMessage = error.localizedDescription
    }
  }

  public func connect(to peer: DiscoveredPeer) {
    guard peer.endpoint != nil else {
      lastErrorMessage = "\(peer.identity.displayName) is not currently discoverable."
      return
    }
    _ = session(for: peer)
  }

  public func connectManually(to endpoint: String) {
    guard let endpoint = parseEndpoint(endpoint) else {
      lastErrorMessage = "Enter an address like 192.168.1.20:53317."
      return
    }
    let identity = DeviceIdentity(
      deviceID: "manual:\(endpoint)",
      displayName: String(describing: endpoint),
      platform: .unknown,
      publicKey: ""
    )
    let peer = DiscoveredPeer(
      identity: identity,
      endpoint: endpoint,
      endpointDescription: String(describing: endpoint),
      isTrusted: false
    )
    discoveredPeers.removeAll { $0.identity.deviceID == identity.deviceID }
    discoveredPeers.append(peer)
    _ = session(for: peer)
  }

  public func disconnect(peerID: String) {
    sessionsByPeerID[peerID]?.sendDisconnect()
    sessionsByPeerID[peerID]?.cancel()
    sessionsByPeerID.removeValue(forKey: peerID)
    connectedPeerIDs.remove(peerID)
    clearEphemeralTransfers(peerID: peerID)
  }

  public func isConnected(peerID: String) -> Bool {
    connectedPeerIDs.contains(peerID)
  }

  public func peer(for trusted: TrustedPeer) -> DiscoveredPeer {
    if let discovered = discoveredPeers.first(where: { $0.identity.deviceID == trusted.deviceID }) {
      return discovered
    }
    if let placeholder = discoveredPeers.first(where: { $0.identity.displayName.hasPrefix(trusted.displayName) }) {
      return DiscoveredPeer(
        identity: DeviceIdentity(
          deviceID: trusted.deviceID,
          displayName: trusted.displayName,
          platform: trusted.platform,
          publicKey: trusted.publicKey
        ),
        endpoint: placeholder.endpoint,
        endpointDescription: placeholder.endpointDescription,
        isTrusted: true
      )
    }
    return DiscoveredPeer(
      identity: DeviceIdentity(
        deviceID: trusted.deviceID,
        displayName: trusted.displayName,
        platform: trusted.platform,
        publicKey: trusted.publicKey
      ),
      endpoint: directEndpoint(for: trusted),
      endpointDescription: endpointDescription(for: trusted),
      isTrusted: true
    )
  }

  public func peer(forPeerID peerID: String) -> DiscoveredPeer? {
    if let discovered = discoveredPeers.first(where: { $0.identity.deviceID == peerID }) {
      return discovered
    }
    guard let trusted = trustedPeers.first(where: { $0.deviceID == peerID }) else { return nil }
    return peer(for: trusted)
  }

  public func resolvedPeer(_ peer: DiscoveredPeer) -> DiscoveredPeer {
    self.peer(forPeerID: peer.identity.deviceID) ?? peer
  }

  public func clearMessages(peerID: String) {
    do {
      try messageStore.clearMessages(peerID: peerID)
      messages.removeAll { $0.peerID == peerID }
    } catch {
      lastErrorMessage = error.localizedDescription
    }
  }

  public func clearTransfers(peerID: String) {
    do {
      try transferStore.clearTransfers(peerID: peerID)
      for transfer in transfers where transfer.peerID == peerID {
        transferPayloads.removeValue(forKey: transfer.id)
      }
      transfers.removeAll { $0.peerID == peerID }
    } catch {
      lastErrorMessage = error.localizedDescription
    }
  }

  public func localFileURL(for transfer: TransferItem) -> URL? {
    if let downloadedPath = transfer.downloadedPath {
      return URL(fileURLWithPath: downloadedPath)
    }
    return nil
  }

  public func transferData(for transfer: TransferItem) -> Data? {
    if let data = transferPayloads[transfer.id] {
      return data
    }
    guard let url = localFileURL(for: transfer) else { return nil }
    return try? Data(contentsOf: url)
  }

  @discardableResult
  public func downloadTransfer(_ transfer: TransferItem) throws -> URL {
    if let existingURL = localFileURL(for: transfer), FileManager.default.fileExists(atPath: existingURL.path) {
      return existingURL
    }
    guard let data = transferPayloads[transfer.id] else {
      throw LocalLinkAppModelError.missingLocalFile
    }
    let directory = Self.downloadsDirectory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = uniqueFileURL(in: directory, fileName: transfer.fileName)
    if FileManager.default.fileExists(atPath: destination.path) {
      try FileManager.default.removeItem(at: destination)
    }
    try data.write(to: destination, options: [.atomic])
    updateTransfer(transfer.id) {
      $0.downloadedPath = destination.path
    }
    persistTransfers()
    return destination
  }

  public func sendText(_ text: String, to peer: DiscoveredPeer) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false else { return }
    let peer = resolvedPeer(peer)
    guard canSend(to: peer.identity) else {
      lastErrorMessage = sendBlockedMessage(for: peer.identity)
      return
    }
    guard let session = session(for: peer) else {
      lastErrorMessage = "\(peer.identity.displayName) is disconnected."
      return
    }
    session.sendText(trimmed)
    appendMessage(ConversationMessage(peerID: peer.identity.deviceID, isOutgoing: true, text: trimmed))
  }

  public func sendFile(_ url: URL, to peer: DiscoveredPeer, contentType: String? = nil) {
    let peer = resolvedPeer(peer)
    guard canSend(to: peer.identity) else {
      lastErrorMessage = sendBlockedMessage(for: peer.identity)
      return
    }
    do {
      let data = try Data(contentsOf: url)
      let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
      let transfer = TransferItem(
        peerID: peer.identity.deviceID,
        direction: .outgoing,
        fileName: url.lastPathComponent,
        contentType: contentType,
        totalBytes: size?.int64Value ?? 0,
        status: .inProgress
      )
      transferPayloads[transfer.id] = data
      upsert(transfer)
      guard let session = session(for: peer) else {
        lastErrorMessage = "\(peer.identity.displayName) is disconnected."
        return
      }
      try session.sendData(data, fileName: url.lastPathComponent, contentType: contentType)
      markTransferComplete(transfer.id)
    } catch {
      lastErrorMessage = error.localizedDescription
    }
  }

  public func sendData(_ data: Data, fileName: String, contentType: String? = nil, to peer: DiscoveredPeer) {
    let peer = resolvedPeer(peer)
    guard canSend(to: peer.identity) else {
      lastErrorMessage = sendBlockedMessage(for: peer.identity)
      return
    }
    do {
      let transfer = TransferItem(
        peerID: peer.identity.deviceID,
        direction: .outgoing,
        fileName: fileName,
        contentType: contentType,
        totalBytes: Int64(data.count),
        status: .inProgress
      )
      transferPayloads[transfer.id] = data
      upsert(transfer)
      guard let session = session(for: peer) else {
        lastErrorMessage = "\(peer.identity.displayName) is disconnected."
        return
      }
      try session.sendData(data, fileName: fileName, contentType: contentType)
      markTransferComplete(transfer.id)
    } catch {
      lastErrorMessage = error.localizedDescription
    }
  }

  private func install(_ session: PeerSession) {
    session.onRemoteIdentity = { [weak self] identity in
      Task { @MainActor in
        self?.sessionsByPeerID[identity.deviceID] = session
        self?.connectedPeerIDs.insert(identity.deviceID)
        self?.mergeRemoteIdentity(
          identity,
          endpoint: session.remoteDirectEndpoint,
          endpointDescription: session.endpointDescription
        )
        if self?.pendingPairRequests.remove(identity.deviceID) != nil {
          let code = self?.pairingCode(for: identity)
          if let code {
            self?.pendingPairingCodes[identity.deviceID] = code
          }
          session.sendPairRequest(code: code)
        }
      }
    }
    session.addStateChangeHandler { [weak self] state in
      Task { @MainActor in
        guard let identity = session.remoteIdentity else { return }
        switch state {
        case .cancelled, .failed:
          self?.sessionsByPeerID.removeValue(forKey: identity.deviceID)
          self?.connectedPeerIDs.remove(identity.deviceID)
          self?.clearEphemeralTransfers(peerID: identity.deviceID)
        default:
          break
        }
      }
    }
    session.onFrame = { [weak self] frame, identity in
      Task { @MainActor in self?.handle(frame, from: identity, session: session) }
    }
    session.onError = { [weak self] error in
      Task { @MainActor in
        guard self?.isBenignCancellation(error) == false else { return }
        self?.lastErrorMessage = error.localizedDescription
      }
    }
  }

  private func handle(_ frame: WireFrame, from identity: DeviceIdentity?, session: PeerSession) {
    guard let identity else { return }

    switch frame.header.kind {
    case .hello:
      break
    case .pairRequest:
      pendingPairingCodes[identity.deviceID] = frame.header.metadata["code"] ?? pairingCode(for: identity)
      showPairingPrompt(for: identity)
    case .pairConfirm:
      completePairingIfCodeMatches(frame, identity: identity)
    case .pairAccepted:
      completePairingIfCodeMatches(frame, identity: identity)
    case .auth:
      break
    case .text:
      guard canSend(to: identity) else {
        session.sendError(sendBlockedMessage(for: identity))
        return
      }
      appendMessage(ConversationMessage(peerID: identity.deviceID, isOutgoing: false, text: String(decoding: frame.payload, as: UTF8.self)))
    case .fileOffer:
      guard canSend(to: identity) else {
        session.sendError(sendBlockedMessage(for: identity))
        return
      }
      if let transfer = transferAssembler.acceptOffer(peerID: identity.deviceID, frame: frame) {
        upsert(transfer)
      }
    case .fileChunk:
      guard canSend(to: identity) else {
        session.sendError(sendBlockedMessage(for: identity))
        return
      }
      do {
        upsert(try transferAssembler.appendChunk(frame))
      } catch {
        lastErrorMessage = error.localizedDescription
      }
    case .fileComplete:
      guard canSend(to: identity) else {
        session.sendError(sendBlockedMessage(for: identity))
        return
      }
      do {
        let (transfer, data) = try transferAssembler.complete(frame)
        var completedTransfer = transfer
        completedTransfer.localPath = nil
        completedTransfer.downloadedPath = nil
        transferPayloads[completedTransfer.id] = data
        upsert(completedTransfer)
      } catch {
        lastErrorMessage = error.localizedDescription
      }
    case .cancel:
      if let transferID = frame.header.transferID {
        updateTransfer(transferID) { $0.status = .cancelled }
      }
    case .disconnect:
      sessionsByPeerID.removeValue(forKey: identity.deviceID)
      connectedPeerIDs.remove(identity.deviceID)
      clearEphemeralTransfers(peerID: identity.deviceID)
      session.cancel()
    case .error:
      lastErrorMessage = frame.header.metadata["message"] ?? "Peer reported an error."
    }
  }

  private func session(for peer: DiscoveredPeer) -> PeerSession? {
    if let session = sessionsByPeerID[peer.identity.deviceID] {
      return session
    }
    let session = service?.connect(to: peer)
    if let session {
      sessionsByPeerID[peer.identity.deviceID] = session
    }
    return session
  }

  @discardableResult
  private func showPairingPrompt(for identity: DeviceIdentity) -> String? {
    guard let localIdentity, identity.deviceID != localIdentity.deviceID else { return nil }
    let code = pairingCode(for: identity)
    pendingPairingCodes[identity.deviceID] = code
    if !isTrusted(identity) {
      pairingPrompt = PairingPrompt(identity: identity, code: code)
    }
    return code
  }

  private func pairingCode(for identity: DeviceIdentity) -> String {
    PairingCode.derive(
      localPublicKey: localIdentity?.publicKey ?? "",
      remotePublicKey: identity.publicKey
    )
  }

  private func completePairingIfCodeMatches(_ frame: WireFrame, identity: DeviceIdentity) {
    guard frame.header.metadata["code"] == pendingPairingCodes[identity.deviceID] else {
      sessionsByPeerID[identity.deviceID]?.sendError("Pairing code mismatch.")
      return
    }
    completePairing(with: identity)
  }

  private func mergeDiscovered(_ peers: [DiscoveredPeer]) {
    var merged = peers.map { peer in
      var copy = peer
      if let trusted = trustedPeers.first(where: { copy.identity.displayName.hasPrefix($0.displayName) }) {
        copy.identity = DeviceIdentity(
          deviceID: trusted.deviceID,
          displayName: trusted.displayName,
          platform: trusted.platform,
          publicKey: trusted.publicKey
        )
        copy.isTrusted = true
      } else {
        copy.isTrusted = trustedPeers.contains { trusted in
          trusted.deviceID == copy.identity.deviceID && trusted.publicKey == copy.identity.publicKey
        }
      }
      return copy
    }

    for existing in discoveredPeers where connectedPeerIDs.contains(existing.identity.deviceID) {
      if !merged.contains(where: { $0.identity.deviceID == existing.identity.deviceID }) {
        merged.append(existing)
      }
    }
    for peer in merged where peer.isTrusted {
      saveTrustedEndpointIfNeeded(for: peer)
    }
    discoveredPeers = merged
  }

  private func mergeRemoteIdentity(_ identity: DeviceIdentity, endpoint: NWEndpoint?, endpointDescription: String) {
    let trusted = trustedPeers.contains { $0.deviceID == identity.deviceID && $0.publicKey == identity.publicKey }
    let previousSelection = selectedPeerID
    let matchedPlaceholder = discoveredPeers.first {
      $0.endpointDescription == endpointDescription || $0.identity.deviceID == previousSelection
    }
    let peer = DiscoveredPeer(
      identity: identity,
      endpoint: endpoint ?? matchedPlaceholder?.endpoint,
      endpointDescription: endpointDescription,
      isTrusted: trusted
    )
    discoveredPeers.removeAll { $0.identity.deviceID == identity.deviceID || $0.endpointDescription == endpointDescription }
    discoveredPeers.append(peer)
    saveTrustedEndpointIfNeeded(for: peer)
    if previousSelection == matchedPlaceholder?.identity.deviceID {
      selectedPeerID = identity.deviceID
    }
  }

  private func trustedPeer(identity: DeviceIdentity, lastHost: String?, lastPort: UInt16?) -> TrustedPeer {
    let existing = trustedPeers.first { $0.deviceID == identity.deviceID }
    return TrustedPeer(
      identity: identity,
      pairedAt: existing?.pairedAt ?? Date(),
      lastSeenAt: Date(),
      lastHost: lastHost ?? existing?.lastHost,
      lastPort: lastPort ?? existing?.lastPort
    )
  }

  private func saveTrustedEndpointIfNeeded(for peer: DiscoveredPeer) {
    guard
      let trusted = trustedPeers.first(where: { $0.deviceID == peer.identity.deviceID && $0.publicKey == peer.identity.publicKey })
    else {
      return
    }
    let (host, port) = hostPort(from: peer.endpoint)
    guard host != nil || port != nil else { return }
    guard trusted.lastHost != host || trusted.lastPort != port else { return }

    do {
      try trustedStore.saveTrustedPeer(trustedPeer(identity: peer.identity, lastHost: host, lastPort: port))
      trustedPeers = try trustedStore.loadTrustedPeers()
    } catch {
      lastErrorMessage = error.localizedDescription
    }
  }

  private func directEndpoint(for trusted: TrustedPeer) -> NWEndpoint? {
    guard
      let host = trusted.lastHost,
      let portValue = trusted.lastPort,
      let port = NWEndpoint.Port(rawValue: portValue)
    else {
      return nil
    }
    return .hostPort(host: NWEndpoint.Host(host), port: port)
  }

  private func endpointDescription(for trusted: TrustedPeer) -> String {
    guard let host = trusted.lastHost, let port = trusted.lastPort else { return "Offline" }
    return "\(host):\(port)"
  }

  private func hostPort(from endpoint: NWEndpoint?) -> (String?, UInt16?) {
    guard case let .hostPort(host, port) = endpoint else { return (nil, nil) }
    return ("\(host)", port.rawValue)
  }

  private func parseEndpoint(_ text: String) -> NWEndpoint? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false else { return nil }
    let defaultPort: UInt16 = 53317
    let hostText: String
    let portValue: UInt16

    if let separator = trimmed.lastIndex(of: ":") {
      hostText = String(trimmed[..<separator]).trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
      guard let parsedPort = UInt16(trimmed[trimmed.index(after: separator)...]) else { return nil }
      portValue = parsedPort
    } else {
      hostText = trimmed
      portValue = defaultPort
    }

    guard hostText.isEmpty == false, let port = NWEndpoint.Port(rawValue: portValue) else { return nil }
    return .hostPort(host: NWEndpoint.Host(hostText), port: port)
  }

  private func canSend(to identity: DeviceIdentity) -> Bool {
    isTrusted(identity) &&
      connectedPeerIDs.contains(identity.deviceID)
  }

  private func isTrusted(_ identity: DeviceIdentity) -> Bool {
    trustedPeers.contains { $0.deviceID == identity.deviceID && $0.publicKey == identity.publicKey }
  }

  private func sendBlockedMessage(for identity: DeviceIdentity) -> String {
    let trusted = trustedPeers.contains { $0.deviceID == identity.deviceID && $0.publicKey == identity.publicKey }
    if !trusted {
      return "Pair with \(identity.displayName) before sending."
    }
    return "\(identity.displayName) is disconnected."
  }

  private func appendMessage(_ message: ConversationMessage) {
    messages.append(message)
    do {
      try messageStore.saveMessages(messages)
    } catch {
      lastErrorMessage = error.localizedDescription
    }
  }

  private func upsert(_ transfer: TransferItem) {
    if let index = transfers.firstIndex(where: { $0.id == transfer.id }) {
      transfers[index] = transfer
    } else {
      transfers.append(transfer)
    }
    persistTransfers()
  }

  private func updateTransfer(_ id: UUID, mutate: (inout TransferItem) -> Void) {
    guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
    mutate(&transfers[index])
    persistTransfers()
  }

  private func markTransferComplete(_ id: UUID) {
    updateTransfer(id) {
      $0.completedBytes = $0.totalBytes
      $0.status = .complete
    }
  }

  private func clearEphemeralTransfers(peerID: String) {
    let ephemeralIDs = Set(
      transfers
        .filter { $0.peerID == peerID && $0.downloadedPath == nil }
        .map(\.id)
    )
    guard !ephemeralIDs.isEmpty else { return }
    for id in ephemeralIDs {
      transferPayloads.removeValue(forKey: id)
    }
    transfers.removeAll { ephemeralIDs.contains($0.id) }
    persistTransfers()
  }

  private func clearAllEphemeralTransfers() {
    let ephemeralIDs = Set(transfers.filter { $0.downloadedPath == nil }.map(\.id))
    guard !ephemeralIDs.isEmpty || !transferPayloads.isEmpty else { return }
    for id in ephemeralIDs {
      transferPayloads.removeValue(forKey: id)
    }
    transfers.removeAll { ephemeralIDs.contains($0.id) }
    transferPayloads.removeAll()
    persistTransfers()
  }

  private func uniqueFileURL(in directory: URL, fileName: String) -> URL {
    let baseURL = directory.appendingPathComponent(fileName)
    guard FileManager.default.fileExists(atPath: baseURL.path) else { return baseURL }

    let baseName = baseURL.deletingPathExtension().lastPathComponent
    let fileExtension = baseURL.pathExtension
    for index in 1...999 {
      let candidateName = fileExtension.isEmpty ? "\(baseName)-\(index)" : "\(baseName)-\(index).\(fileExtension)"
      let candidate = directory.appendingPathComponent(candidateName)
      if !FileManager.default.fileExists(atPath: candidate.path) {
        return candidate
      }
    }
    return directory.appendingPathComponent("\(UUID().uuidString)-\(fileName)")
  }

  private func persistTransfers() {
    do {
      try transferStore.saveTransfers(transfers)
    } catch {
      lastErrorMessage = error.localizedDescription
    }
  }

  private func isBenignCancellation(_ error: Error) -> Bool {
    if let nwError = error as? NWError {
      if case .posix(.ECANCELED) = nwError { return true }
      if "\(nwError)".contains("Operation canceled") { return true }
    }
    return (error as NSError).code == 89 && String(describing: error).contains("NWError")
  }

  private static func downloadsDirectory() -> URL {
    #if os(macOS)
    FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("LocalLink", isDirectory: true)
    #else
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("LocalLink Downloads", isDirectory: true)
    #endif
  }

  private static func defaultDeviceName() -> String {
    #if os(macOS)
    return Host.current().localizedName ?? "My Mac"
    #elseif os(iOS)
    return "My iPhone"
    #else
    return "My Device"
    #endif
  }
}

public enum LocalLinkAppModelError: LocalizedError {
  case missingLocalFile

  public var errorDescription: String? {
    switch self {
    case .missingLocalFile:
      return "The file is not available locally."
    }
  }
}

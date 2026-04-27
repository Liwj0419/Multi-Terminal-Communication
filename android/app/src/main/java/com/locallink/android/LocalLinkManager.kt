package com.locallink.android

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import java.net.Inet4Address
import java.net.InetAddress
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class LocalLinkManager(private val context: Context) {
  companion object {
    const val SERVICE_TYPE = "_locallink._tcp."
    private const val DEFAULT_PORT = 53317
  }

  private val main = Handler(Looper.getMainLooper())
  private val executor: ExecutorService = Executors.newCachedThreadPool()
  private val stores = LocalStores(context)
  private val nsd = context.getSystemService(Context.NSD_SERVICE) as NsdManager
  private val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
  private val assembler = TransferAssembler()

  var local: LocalIdentity = stores.loadOrCreateIdentity()
    private set
  val peers = mutableListOf<DiscoveredPeer>()
  val connectedPeerIDs = mutableSetOf<String>()
  val messages = stores.loadMessages()
  val transfers = mutableListOf<TransferItem>()
  val payloads = mutableMapOf<String, ByteArray>()
  var isRunning = false
    private set

  var onChanged: (() -> Unit)? = null
  var onPairRequest: ((DeviceIdentity, String) -> Unit)? = null
  var onError: ((String) -> Unit)? = null

  private var multicastLock: WifiManager.MulticastLock? = null
  private var server: ServerSocket? = null
  private var sessions = mutableMapOf<String, PeerSession>()
  private var pendingPairCodes = mutableMapOf<String, String>()
  private var pendingPairRequests = mutableSetOf<String>()
  private var registrationListener: NsdManager.RegistrationListener? = null
  private var discoveryListener: NsdManager.DiscoveryListener? = null

  fun start() {
    if (isRunning) return
    multicastLock = wifi.createMulticastLock("LocalLink").apply {
      setReferenceCounted(true)
      acquire()
    }
    startServer()
    registerService()
    discover()
    isRunning = true
    notifyChanged()
  }

  fun stop() {
    if (!isRunning) return
    runCatching { discoveryListener?.let { nsd.stopServiceDiscovery(it) } }
    runCatching { registrationListener?.let { nsd.unregisterService(it) } }
    runCatching { server?.close() }
    server = null
    registrationListener = null
    discoveryListener = null
    sessions.values.forEach { it.close(false) }
    sessions.clear()
    connectedPeerIDs.clear()
    peers.clear()
    clearAllEphemeralTransfers()
    runCatching { multicastLock?.release() }
    multicastLock = null
    isRunning = false
    notifyChanged()
  }

  fun connect(peer: DiscoveredPeer) {
    val resolved = resolve(peer)
    if (sessions[resolved.identity.deviceID] != null) return
    if (resolved.host.isBlank() || resolved.port <= 0) {
      error("${resolved.identity.displayName} is not currently discoverable.")
      return
    }
    executor.execute {
      runCatching {
        install(PeerSession(Socket(resolved.host, resolved.port), local, waitForPort(), executor, ::onHello, ::onFrame, ::onClosed, ::onError))
      }.onFailure { onError(it) }
    }
  }

  fun connectManually(endpoint: String) {
    val parsed = parseEndpoint(endpoint)
    if (parsed == null) {
      error("Enter an address like 192.168.1.20:53317.")
      return
    }
    executor.execute {
      runCatching {
        install(PeerSession(Socket(parsed.first, parsed.second), local, waitForPort(), executor, ::onHello, ::onFrame, ::onClosed, ::onError))
      }.onFailure { onError(it) }
    }
  }

  fun pair(peer: DiscoveredPeer) {
    val resolved = resolve(peer)
    if (stores.isTrusted(resolved.identity)) {
      connect(resolved)
      return
    }
    val code = LocalLinkHashes.pairingCode(local.identity.publicKey, resolved.identity.publicKey)
    pendingPairCodes[resolved.identity.deviceID] = code
    pendingPairRequests += resolved.identity.deviceID
    connect(resolved)
    sessions[resolved.identity.deviceID]?.sendPairRequest(code)
  }

  fun acceptPair(identity: DeviceIdentity) {
    val code = pendingPairCodes[identity.deviceID] ?: LocalLinkHashes.pairingCode(local.identity.publicKey, identity.publicKey)
    saveTrustedEndpoint(identity)
    markTrusted(identity)
    sessions[identity.deviceID]?.sendPairAccepted(code)
    notifyChanged()
  }

  fun disconnect(peerID: String) {
    sessions.remove(peerID)?.close(true)
    connectedPeerIDs.remove(peerID)
    clearEphemeralTransfers(peerID)
    notifyChanged()
  }

  fun updateDeviceName(displayName: String) {
    val wasRunning = isRunning
    if (wasRunning) stop()
    local = stores.updateDisplayName(displayName)
    if (wasRunning) {
      start()
    } else {
      notifyChanged()
    }
  }

  fun sendText(peer: DiscoveredPeer, text: String) {
    val trimmed = text.trim()
    if (trimmed.isBlank()) return
    if (!canSend(peer.identity)) {
      error("Pair and connect before sending.")
      return
    }
    sessions[peer.identity.deviceID]?.sendText(trimmed)
    messages += MessageItem(peer.identity.deviceID, true, trimmed)
    stores.saveMessages(messages)
    notifyChanged()
  }

  fun sendData(peer: DiscoveredPeer, data: ByteArray, fileName: String, contentType: String?) {
    if (!canSend(peer.identity)) {
      error("Pair and connect before sending.")
      return
    }
    val item = TransferItem(
      id = java.util.UUID.randomUUID().toString(),
      peerID = peer.identity.deviceID,
      outgoing = true,
      fileName = fileName,
      contentType = contentType,
      totalBytes = data.size.toLong(),
      completedBytes = data.size.toLong(),
      checksum = LocalLinkHashes.sha256Hex(data),
      complete = true
    )
    payloads[item.id] = data
    upsertTransfer(item)
    sessions[peer.identity.deviceID]?.sendData(data, fileName, contentType)
  }

  fun markDownloaded(id: String) {
    val index = transfers.indexOfFirst { it.id == id }
    if (index >= 0) {
      transfers[index] = transfers[index].copy(downloaded = true)
      notifyChanged()
    }
  }

  fun forget(peerID: String) {
    stores.forget(peerID)
    disconnect(peerID)
    for (index in peers.indices) {
      val peer = peers[index]
      if (peer.identity.deviceID == peerID) {
        peers[index] = peer.copy(trusted = false)
      }
    }
    notifyChanged()
  }

  fun trustedIdentities(): List<TrustedPeer> = stores.trustedPeers()

  fun connectionAddresses(): List<String> {
    val port = server?.localPort ?: return emptyList()
    if (port <= 0) return emptyList()
    return localIPv4Addresses().map { "$it:$port" }
  }

  fun clearMessages(peerID: String) {
    messages.removeAll { it.peerID == peerID }
    stores.saveMessages(messages)
    notifyChanged()
  }

  fun clearTransfers(peerID: String) {
    val ids = transfers.filter { it.peerID == peerID }.map { it.id }.toSet()
    transfers.removeAll { ids.contains(it.id) }
    ids.forEach { payloads.remove(it) }
    notifyChanged()
  }

  private fun startServer() {
    executor.execute {
      val socket = runCatching { ServerSocket(DEFAULT_PORT) }.getOrElse { ServerSocket(0) }
      server = socket
      while (!socket.isClosed) {
        runCatching {
          install(PeerSession(socket.accept(), local, socket.localPort, executor, ::onHello, ::onFrame, ::onClosed, ::onError))
        }.onFailure {
          if (!socket.isClosed) onError(it)
        }
      }
    }
  }

  private fun registerService() {
    val service = NsdServiceInfo().apply {
      serviceName = "${local.identity.displayName}-${local.identity.deviceID.take(8)}"
      serviceType = SERVICE_TYPE
      port = waitForPort()
      setAttribute("id", local.identity.deviceID)
      setAttribute("name", local.identity.displayName)
      setAttribute("platform", "android")
      setAttribute("version", local.identity.protocolVersion.toString())
      setAttribute("publicKey", local.identity.publicKey)
      localIPv4Addresses().firstOrNull()?.let { setAttribute("host", it) }
      setAttribute("port", port.toString())
    }
    val listener = object : NsdManager.RegistrationListener {
      override fun onServiceRegistered(serviceInfo: NsdServiceInfo) {}
      override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) = error("NSD registration failed: $errorCode")
      override fun onServiceUnregistered(serviceInfo: NsdServiceInfo) {}
      override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) = error("NSD unregister failed: $errorCode")
    }
    registrationListener = listener
    nsd.registerService(service, NsdManager.PROTOCOL_DNS_SD, listener)
  }

  private fun waitForPort(): Int {
    while (server?.localPort == null) Thread.sleep(20)
    return server!!.localPort
  }

  private fun localIPv4Addresses(): List<String> =
    NetworkInterface.getNetworkInterfaces().asSequence()
      .filter { isPhysicalLanInterface(it) }
      .flatMap { network ->
        network.inetAddresses.asSequence()
          .filterIsInstance<Inet4Address>()
          .mapNotNull { address ->
            address.hostAddress
              ?.takeIf { isUsableLanIPv4(it) }
              ?.let { Triple(interfacePriority(network.name), network.name, it) }
          }
      }
      .sortedWith(compareBy<Triple<Int, String, String>> { it.first }.thenBy { it.second })
      .take(1)
      .map { it.third }
      .toList()

  private fun isPhysicalLanInterface(network: NetworkInterface): Boolean {
    val name = network.name.lowercase()
    return network.isUp &&
      !network.isLoopback &&
      !network.isVirtual &&
      !network.isPointToPoint &&
      (name.startsWith("wlan") || name.startsWith("eth"))
  }

  private fun interfacePriority(name: String): Int =
    when {
      name.equals("wlan0", ignoreCase = true) -> 0
      name.startsWith("wlan", ignoreCase = true) -> 1
      name.equals("eth0", ignoreCase = true) -> 10
      else -> 20
    }

  private fun isUsableLanIPv4(address: String): Boolean =
    !address.startsWith("0.") &&
      !address.startsWith("127.") &&
      !address.startsWith("169.254.")

  private fun discover() {
    val listener = object : NsdManager.DiscoveryListener {
      override fun onDiscoveryStarted(serviceType: String) {}
      override fun onDiscoveryStopped(serviceType: String) {}
      override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) = error("NSD discovery failed: $errorCode")
      override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = error("NSD stop failed: $errorCode")
      override fun onServiceLost(serviceInfo: NsdServiceInfo) {
        val lostID = serviceInfo.attributes["id"]?.toString(Charsets.UTF_8)
        if (lostID != null) {
          peers.removeAll { it.identity.deviceID == lostID }
          notifyChanged()
        }
      }
      override fun onServiceFound(serviceInfo: NsdServiceInfo) {
        if (!serviceInfo.serviceType.startsWith("_locallink._tcp")) return
        nsd.resolveService(serviceInfo, object : NsdManager.ResolveListener {
          override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {}
          override fun onServiceResolved(resolved: NsdServiceInfo) {
            addResolvedPeer(resolved)
          }
        })
      }
    }
    discoveryListener = listener
    nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
  }

  private fun addResolvedPeer(service: NsdServiceInfo) {
    val attrs = service.attributes.mapValues { it.value.toString(Charsets.UTF_8) }
    val id = attrs["id"] ?: return
    if (id == local.identity.deviceID) return
    val host: InetAddress = service.host ?: return
    val identity = DeviceIdentity(
      deviceID = id,
      displayName = attrs["name"] ?: service.serviceName,
      platform = attrs["platform"] ?: "unknown",
      publicKey = attrs["publicKey"] ?: "",
      protocolVersion = attrs["version"]?.toIntOrNull() ?: 1
    )
    val hostAddress = host.hostAddress ?: return
    val peer = DiscoveredPeer(identity, hostAddress, service.port, stores.isTrusted(identity))
    if (peer.trusted) {
      stores.saveTrusted(identity, hostAddress, service.port)
    }
    peers.removeAll { it.identity.deviceID == id }
    peers += peer
    notifyChanged()
  }

  private fun install(session: PeerSession) {
    session.start()
  }

  private fun onHello(session: PeerSession, identity: DeviceIdentity) {
    sessions[identity.deviceID] = session
    connectedPeerIDs += identity.deviceID
    if (stores.isTrusted(identity)) {
      saveTrustedEndpoint(identity, session)
    }
    if (pendingPairRequests.remove(identity.deviceID)) {
      val code = pendingPairCodes[identity.deviceID] ?: LocalLinkHashes.pairingCode(local.identity.publicKey, identity.publicKey)
      pendingPairCodes[identity.deviceID] = code
      session.sendPairRequest(code)
    }
    val peer = peers.firstOrNull { it.identity.deviceID == identity.deviceID }
    if (peer == null && identity.deviceID != local.identity.deviceID) {
      peers += DiscoveredPeer(identity, session.remoteHost, session.remoteListenPort, stores.isTrusted(identity))
    }
    notifyChanged()
  }

  private fun onFrame(session: PeerSession, frame: WireFrame, identity: DeviceIdentity?) {
    identity ?: return
    when (frame.kind) {
      FrameKind.hello -> Unit
      FrameKind.pairRequest -> {
        val code = frame.metadata["code"] ?: LocalLinkHashes.pairingCode(local.identity.publicKey, identity.publicKey)
        pendingPairCodes[identity.deviceID] = code
        main.post { onPairRequest?.invoke(identity, code) }
      }
      FrameKind.pairAccepted, FrameKind.pairConfirm -> {
        if (frame.metadata["code"] == pendingPairCodes[identity.deviceID]) {
          saveTrustedEndpoint(identity, session)
          markTrusted(identity)
          pendingPairCodes.remove(identity.deviceID)
          notifyChanged()
        } else {
          session.sendError("Pairing code mismatch.")
        }
      }
      FrameKind.text -> {
        if (!canSend(identity)) {
          session.sendError("Pair before sending.")
          return
        }
        messages += MessageItem(identity.deviceID, false, String(frame.payload, Charsets.UTF_8))
        stores.saveMessages(messages)
        notifyChanged()
      }
      FrameKind.fileOffer -> {
        if (!canSend(identity)) {
          session.sendError("Pair before sending.")
          return
        }
        assembler.acceptOffer(identity.deviceID, frame)?.let { upsertTransfer(it) }
      }
      FrameKind.fileChunk -> assembler.appendChunk(frame)?.let { upsertTransfer(it) }
      FrameKind.fileComplete -> {
        val completed = assembler.complete(frame) ?: return
        if (completed.second.isNotEmpty()) {
          payloads[completed.first.id] = completed.second
        }
        upsertTransfer(completed.first)
      }
      FrameKind.disconnect -> {
        sessions.remove(identity.deviceID)
        connectedPeerIDs.remove(identity.deviceID)
        clearEphemeralTransfers(identity.deviceID)
        notifyChanged()
      }
      FrameKind.cancel -> frame.transferID?.let { id ->
        transfers.removeAll { it.id == id }
        payloads.remove(id)
        notifyChanged()
      }
      FrameKind.error -> error(frame.metadata["message"] ?: "Peer reported an error.")
      FrameKind.auth -> Unit
    }
  }

  private fun onClosed(session: PeerSession) {
    val id = session.remoteIdentity?.deviceID ?: return
    if (sessions[id] === session) sessions.remove(id)
    connectedPeerIDs.remove(id)
    clearEphemeralTransfers(id)
    notifyChanged()
  }

  private fun onError(error: Throwable) {
    error(error.localizedMessage ?: error.toString())
  }

  private fun canSend(identity: DeviceIdentity): Boolean =
    stores.isTrusted(identity) && connectedPeerIDs.contains(identity.deviceID)

  private fun markTrusted(identity: DeviceIdentity) {
    for (index in peers.indices) {
      val peer = peers[index]
      if (peer.identity.deviceID == identity.deviceID) {
        peers[index] = peer.copy(trusted = true)
      }
    }
    connectedPeerIDs += identity.deviceID
  }

  private fun resolve(peer: DiscoveredPeer): DiscoveredPeer {
    val discovered = peers.firstOrNull { it.identity.deviceID == peer.identity.deviceID }
    if (discovered != null) return discovered
    val trusted = stores.trustedPeers().firstOrNull { it.deviceID == peer.identity.deviceID }
    return trusted?.let { peerFor(it) } ?: peer
  }

  fun peerFor(trusted: TrustedPeer): DiscoveredPeer =
    peers.firstOrNull { it.identity.deviceID == trusted.deviceID }
      ?: DiscoveredPeer(trusted.identity, trusted.lastHost.orEmpty(), trusted.lastPort, trusted = true)

  private fun saveTrustedEndpoint(identity: DeviceIdentity, session: PeerSession? = sessions[identity.deviceID]) {
    val peer = peers.firstOrNull { it.identity.deviceID == identity.deviceID }
    val host = peer?.host?.takeIf { it.isNotBlank() } ?: session?.remoteHost
    val port = peer?.port?.takeIf { it > 0 } ?: session?.remoteListenPort ?: 0
    stores.saveTrusted(identity, host, port)
  }

  private fun parseEndpoint(endpoint: String): Pair<String, Int>? {
    val trimmed = endpoint.trim()
    if (trimmed.isBlank()) return null
    val separator = trimmed.lastIndexOf(':')
    val host: String
    val port: Int
    if (separator > 0) {
      host = trimmed.substring(0, separator).trim().trim('[', ']')
      port = trimmed.substring(separator + 1).toIntOrNull() ?: return null
    } else {
      host = trimmed
      port = DEFAULT_PORT
    }
    if (host.isBlank() || port !in 1..65535) return null
    return host to port
  }

  private fun upsertTransfer(item: TransferItem) {
    val index = transfers.indexOfFirst { it.id == item.id }
    if (index >= 0) transfers[index] = item else transfers += item
    notifyChanged()
  }

  private fun clearEphemeralTransfers(peerID: String) {
    val ids = transfers.filter { it.peerID == peerID && !it.downloaded }.map { it.id }.toSet()
    transfers.removeAll { ids.contains(it.id) }
    ids.forEach { payloads.remove(it) }
  }

  private fun clearAllEphemeralTransfers() {
    val ids = transfers.filter { !it.downloaded }.map { it.id }.toSet()
    transfers.removeAll { ids.contains(it.id) }
    ids.forEach { payloads.remove(it) }
  }

  private fun error(message: String) {
    main.post { onError?.invoke(message) }
  }

  private fun notifyChanged() {
    main.post { onChanged?.invoke() }
  }
}

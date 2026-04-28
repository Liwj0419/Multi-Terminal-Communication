using System.Collections.ObjectModel;
using System.IO;

namespace LocalLink.Windows;

public sealed class LocalLinkViewModel
{
    private readonly LocalStores stores = new();
    private readonly TransferAssembler assembler = new();
    private readonly Dictionary<string, PeerSession> sessions = new();
    private readonly Dictionary<string, string> pendingPairingCodes = new();
    private readonly HashSet<string> pendingPairRequests = new();
    private readonly Dictionary<Guid, byte[]> payloads = new();
    private MdnsPeerService? service;
    private LocalDeviceIdentity local;

    public LocalLinkViewModel()
    {
        local = stores.LoadOrCreateIdentity();
        LocalIdentity = local.identity;
        TrustedPeers = new ObservableCollection<TrustedPeer>(stores.LoadTrustedPeers());
        Messages = new ObservableCollection<ConversationMessage>(stores.LoadMessages());
        Transfers = new ObservableCollection<TransferItem>(stores.LoadTransfers());
    }

    public DeviceIdentity LocalIdentity { get; private set; }
    public ObservableCollection<DiscoveredPeer> DiscoveredPeers { get; private set; } = new();
    public ObservableCollection<TrustedPeer> TrustedPeers { get; private set; }
    public ObservableCollection<ConversationMessage> Messages { get; private set; }
    public ObservableCollection<TransferItem> Transfers { get; private set; }
    public HashSet<string> ConnectedPeerIDs { get; } = new();
    public bool IsRunning { get; private set; }
    public IReadOnlyList<string> ConnectionAddresses =>
        service is null || service.Port <= 0
            ? Array.Empty<string>()
            : MdnsPeerService.LocalAddresses.Select(address => $"{address}:{service.Port}").ToList();

    public event Action? Changed;
    public event Action<string>? Error;
    public event Action<DeviceIdentity, string>? PairRequested;

    public void Start()
    {
        if (IsRunning)
        {
            return;
        }

        service = new MdnsPeerService(local, IsTrusted);
        service.PeersChanged += peers =>
        {
            RunOnUi(() =>
            {
                DiscoveredPeers = new ObservableCollection<DiscoveredPeer>(MergeDiscovered(peers));
                Changed?.Invoke();
            });
        };
        service.SessionAccepted += session => RunOnUi(() => Install(session));
        service.Error += ex => RunOnUi(() => Error?.Invoke(ex.Message));
        service.Start();
        IsRunning = true;
        Changed?.Invoke();
    }

    public void Stop()
    {
        ClearAllEphemeralTransfers();
        service?.Stop();
        service = null;
        foreach (var session in sessions.Values.ToList())
        {
            session.Close(false);
        }
        sessions.Clear();
        ConnectedPeerIDs.Clear();
        DiscoveredPeers.Clear();
        IsRunning = false;
        Changed?.Invoke();
    }

    public void UpdateDeviceName(string name)
    {
        var wasRunning = IsRunning;
        if (wasRunning)
        {
            Stop();
        }

        local = stores.UpdateDisplayName(name);
        LocalIdentity = local.identity;
        if (wasRunning)
        {
            Start();
        }
        else
        {
            Changed?.Invoke();
        }
    }

    public void Pair(DiscoveredPeer peer)
    {
        peer = Resolve(peer);
        if (IsTrusted(peer.identity))
        {
            Connect(peer);
            return;
        }

        var code = PairingCode(peer.identity);
        pendingPairingCodes[peer.identity.deviceID] = code;
        pendingPairRequests.Add(peer.identity.deviceID);
        Connect(peer);
        if (sessions.TryGetValue(peer.identity.deviceID, out var session))
        {
            _ = session.SendPairRequestAsync(code);
        }
    }

    public void ConfirmPairing(DeviceIdentity identity)
    {
        var code = pendingPairingCodes.GetValueOrDefault(identity.deviceID) ?? PairingCode(identity);
        CompletePairing(identity, sessions.GetValueOrDefault(identity.deviceID));
        if (sessions.TryGetValue(identity.deviceID, out var session))
        {
            _ = session.SendPairAcceptedAsync(code);
        }
    }

    public void Connect(DiscoveredPeer peer)
    {
        peer = Resolve(peer);
        if (sessions.ContainsKey(peer.identity.deviceID))
        {
            return;
        }

        if (string.IsNullOrWhiteSpace(peer.host) || peer.port <= 0 || service is null)
        {
            Error?.Invoke($"{peer.identity.displayName} is not currently discoverable.");
            return;
        }

        try
        {
            Install(service.Connect(peer));
        }
        catch (Exception ex)
        {
            Error?.Invoke(ex.Message);
        }
    }

    public void ConnectManually(string endpoint)
    {
        if (service is null)
        {
            Error?.Invoke("Start LocalLink before connecting manually.");
            return;
        }

        if (!TryParseEndpoint(endpoint, out var host, out var port))
        {
            Error?.Invoke("Enter an address like 192.168.1.20:53317.");
            return;
        }

        try
        {
            Install(service.Connect(host, port));
        }
        catch (Exception ex)
        {
            Error?.Invoke(ex.Message);
        }
    }

    public void Disconnect(string peerID)
    {
        if (sessions.Remove(peerID, out var session))
        {
            session.Close(true);
        }
        ConnectedPeerIDs.Remove(peerID);
        ClearEphemeralTransfers(peerID);
        Changed?.Invoke();
    }

    public void Forget(string peerID)
    {
        stores.Forget(peerID);
        Disconnect(peerID);
        TrustedPeers = new ObservableCollection<TrustedPeer>(stores.LoadTrustedPeers());
        DiscoveredPeers = new ObservableCollection<DiscoveredPeer>(DiscoveredPeers.Select(peer =>
            peer.identity.deviceID == peerID ? peer with { isTrusted = false } : peer));
        Changed?.Invoke();
    }

    public void ClearMessages(string peerID)
    {
        stores.ClearMessages(peerID);
        Messages = new ObservableCollection<ConversationMessage>(Messages.Where(message => message.peerID != peerID));
        Changed?.Invoke();
    }

    public void ClearTransfers(string peerID)
    {
        stores.ClearTransfers(peerID);
        foreach (var transfer in Transfers.Where(transfer => transfer.peerID == peerID).ToList())
        {
            payloads.Remove(transfer.id);
            Transfers.Remove(transfer);
        }
        Changed?.Invoke();
    }

    public void SendText(DiscoveredPeer peer, string text)
    {
        var trimmed = text.Trim();
        if (string.IsNullOrWhiteSpace(trimmed))
        {
            return;
        }

        peer = Resolve(peer);
        if (!CanSend(peer.identity))
        {
            Error?.Invoke(SendBlockedMessage(peer.identity));
            return;
        }

        if (!sessions.TryGetValue(peer.identity.deviceID, out var session))
        {
            Error?.Invoke($"{peer.identity.displayName} is disconnected.");
            return;
        }

        _ = session.SendTextAsync(trimmed);
        AppendMessage(new ConversationMessage(peer.identity.deviceID, true, trimmed, DateTimeOffset.Now));
    }

    public void SendFile(DiscoveredPeer peer, string path, string? contentType = null)
    {
        peer = Resolve(peer);
        if (!CanSend(peer.identity))
        {
            Error?.Invoke(SendBlockedMessage(peer.identity));
            return;
        }

        if (!sessions.TryGetValue(peer.identity.deviceID, out var session))
        {
            Error?.Invoke($"{peer.identity.displayName} is disconnected.");
            return;
        }

        try
        {
            var data = File.ReadAllBytes(path);
            var item = new TransferItem(
                Guid.NewGuid(),
                peer.identity.deviceID,
                TransferDirection.Outgoing,
                Path.GetFileName(path),
                contentType,
                data.LongLength,
                data.LongLength,
                LocalLinkHashes.Sha256Hex(data),
                TransferStatus.complete,
                null);
            payloads[item.id] = data;
            Upsert(item);
            _ = session.SendDataAsync(data, item.fileName, item.contentType);
        }
        catch (Exception ex)
        {
            Error?.Invoke(ex.Message);
        }
    }

    public byte[]? TransferData(TransferItem transfer)
    {
        if (payloads.TryGetValue(transfer.id, out var data))
        {
            return data;
        }

        return transfer.downloadedPath is not null && File.Exists(transfer.downloadedPath)
            ? File.ReadAllBytes(transfer.downloadedPath)
            : null;
    }

    public string Download(TransferItem transfer)
    {
        if (transfer.downloadedPath is not null && File.Exists(transfer.downloadedPath))
        {
            return transfer.downloadedPath;
        }

        if (!payloads.TryGetValue(transfer.id, out var data))
        {
            throw new InvalidOperationException("File is no longer in memory.");
        }

        var directory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            "Downloads",
            "LocalLink");
        Directory.CreateDirectory(directory);
        var destination = UniqueFilePath(directory, transfer.fileName);
        File.WriteAllBytes(destination, data);
        ReplaceTransfer(transfer with { downloadedPath = destination });
        stores.SaveTransfers(Transfers);
        return destination;
    }

    public DiscoveredPeer Resolve(DiscoveredPeer peer)
    {
        var discovered = DiscoveredPeers.FirstOrDefault(item => item.identity.deviceID == peer.identity.deviceID);
        if (discovered is not null)
        {
            return discovered;
        }

        var trusted = TrustedPeers.FirstOrDefault(item => item.deviceID == peer.identity.deviceID);
        return trusted is null
            ? peer
            : new DiscoveredPeer(
                new DeviceIdentity(trusted.deviceID, trusted.displayName, trusted.platform, trusted.publicKey),
                trusted.lastHost ?? "",
                trusted.lastPort,
                true);
    }

    public DiscoveredPeer? PeerForTrusted(TrustedPeer trusted) =>
        DiscoveredPeers.FirstOrDefault(peer => peer.identity.deviceID == trusted.deviceID) ??
        new DiscoveredPeer(
            new DeviceIdentity(trusted.deviceID, trusted.displayName, trusted.platform, trusted.publicKey),
            trusted.lastHost ?? "",
            trusted.lastPort,
            true);

    private void Install(PeerSession session)
    {
        session.HelloReceived += (receivedSession, identity) => RunOnUi(() =>
        {
            sessions[identity.deviceID] = session;
            ConnectedPeerIDs.Add(identity.deviceID);
            MergeRemoteIdentity(identity, session);
            if (IsTrusted(identity) && !string.IsNullOrWhiteSpace(session.RemoteHost) && session.RemoteListenPort > 0)
            {
                stores.SaveTrusted(identity, session.RemoteHost, session.RemoteListenPort);
                TrustedPeers = new ObservableCollection<TrustedPeer>(stores.LoadTrustedPeers());
            }
            if (pendingPairRequests.Remove(identity.deviceID))
            {
                var code = PairingCode(identity);
                pendingPairingCodes[identity.deviceID] = code;
                _ = receivedSession.SendPairRequestAsync(code);
            }
            Changed?.Invoke();
        });
        session.FrameReceived += (currentSession, frame, identity) => RunOnUi(() => Handle(currentSession, frame, identity));
        session.Closed += closed => RunOnUi(() =>
        {
            var id = closed.RemoteIdentity?.deviceID;
            if (id is not null && sessions.GetValueOrDefault(id) == closed)
            {
                sessions.Remove(id);
                ConnectedPeerIDs.Remove(id);
                ClearEphemeralTransfers(id);
                Changed?.Invoke();
            }
        });
        session.Error += ex => RunOnUi(() => Error?.Invoke(ex.Message));
    }

    private void Handle(PeerSession session, WireFrame frame, DeviceIdentity? identity)
    {
        if (identity is null)
        {
            return;
        }

        switch (frame.Header.kind)
        {
            case FrameKind.hello:
                break;
            case FrameKind.pairRequest:
                pendingPairingCodes[identity.deviceID] =
                    frame.Header.metadata.GetValueOrDefault("code") ?? PairingCode(identity);
                if (!IsTrusted(identity))
                {
                    PairRequested?.Invoke(identity, pendingPairingCodes[identity.deviceID]);
                }
                break;
            case FrameKind.pairAccepted:
            case FrameKind.pairConfirm:
                if (frame.Header.metadata.GetValueOrDefault("code") == pendingPairingCodes.GetValueOrDefault(identity.deviceID))
                {
                    CompletePairing(identity, session);
                }
                else
                {
                    _ = session.SendErrorAsync("Pairing code mismatch.");
                }
                break;
            case FrameKind.text:
                if (!CanSend(identity))
                {
                    _ = session.SendErrorAsync(SendBlockedMessage(identity));
                    return;
                }
                AppendMessage(new ConversationMessage(
                    identity.deviceID,
                    false,
                    System.Text.Encoding.UTF8.GetString(frame.Payload),
                    DateTimeOffset.Now));
                break;
            case FrameKind.fileOffer:
                if (!CanSend(identity))
                {
                    _ = session.SendErrorAsync(SendBlockedMessage(identity));
                    return;
                }
                var offer = assembler.AcceptOffer(identity.deviceID, frame);
                if (offer is not null)
                {
                    Upsert(offer);
                }
                break;
            case FrameKind.fileChunk:
                if (!CanSend(identity))
                {
                    _ = session.SendErrorAsync(SendBlockedMessage(identity));
                    return;
                }
                Upsert(assembler.AppendChunk(frame));
                break;
            case FrameKind.fileComplete:
                if (!CanSend(identity))
                {
                    _ = session.SendErrorAsync(SendBlockedMessage(identity));
                    return;
                }
                var completed = assembler.Complete(frame);
                payloads[completed.Transfer.id] = completed.Data;
                Upsert(completed.Transfer);
                break;
            case FrameKind.disconnect:
                sessions.Remove(identity.deviceID);
                ConnectedPeerIDs.Remove(identity.deviceID);
                ClearEphemeralTransfers(identity.deviceID);
                Changed?.Invoke();
                break;
            case FrameKind.cancel:
                if (frame.Header.transferID is Guid id)
                {
                    ReplaceTransfer(Transfers.First(item => item.id == id) with { status = TransferStatus.cancelled });
                }
                break;
            case FrameKind.error:
                Error?.Invoke(frame.Header.metadata.GetValueOrDefault("message", "Peer reported an error."));
                break;
            case FrameKind.auth:
                break;
        }
    }

    private void CompletePairing(DeviceIdentity identity, PeerSession? session = null)
    {
        var knownPeer = DiscoveredPeers.FirstOrDefault(peer => peer.identity.deviceID == identity.deviceID);
        var host = knownPeer?.host;
        var port = knownPeer?.port ?? 0;
        if ((string.IsNullOrWhiteSpace(host) || port <= 0) && session is not null)
        {
            host = session.RemoteHost;
            port = session.RemoteListenPort;
        }
        stores.SaveTrusted(identity, host, port);
        TrustedPeers = new ObservableCollection<TrustedPeer>(stores.LoadTrustedPeers());
        DiscoveredPeers = new ObservableCollection<DiscoveredPeer>(DiscoveredPeers.Select(peer =>
            peer.identity.deviceID == identity.deviceID ? peer with { isTrusted = true } : peer));
        if (sessions.ContainsKey(identity.deviceID))
        {
            ConnectedPeerIDs.Add(identity.deviceID);
        }
        pendingPairingCodes.Remove(identity.deviceID);
        pendingPairRequests.Remove(identity.deviceID);
        Changed?.Invoke();
    }

    private List<DiscoveredPeer> MergeDiscovered(List<DiscoveredPeer> peers)
    {
        var merged = peers.Select(peer =>
        {
            var trusted = TrustedPeers.FirstOrDefault(item => item.deviceID == peer.identity.deviceID && item.publicKey == peer.identity.publicKey);
            return trusted is null ? peer : peer with { isTrusted = true };
        }).ToList();

        var trustedPeersChanged = false;
        foreach (var peer in merged.Where(peer => peer.isTrusted && !string.IsNullOrWhiteSpace(peer.host) && peer.port > 0))
        {
            var trusted = TrustedPeers.FirstOrDefault(item => item.deviceID == peer.identity.deviceID);
            if (trusted is null ||
                trusted.displayName == peer.identity.displayName &&
                trusted.platform == peer.identity.platform &&
                trusted.publicKey == peer.identity.publicKey &&
                trusted.lastHost == peer.host &&
                trusted.lastPort == peer.port)
            {
                continue;
            }

            stores.SaveTrusted(peer.identity, peer.host, peer.port);
            trustedPeersChanged = true;
        }

        if (trustedPeersChanged)
        {
            TrustedPeers = new ObservableCollection<TrustedPeer>(stores.LoadTrustedPeers());
        }

        foreach (var existing in DiscoveredPeers.Where(peer => ConnectedPeerIDs.Contains(peer.identity.deviceID)))
        {
            if (merged.All(peer => peer.identity.deviceID != existing.identity.deviceID))
            {
                merged.Add(existing);
            }
        }

        return merged;
    }

    private void MergeRemoteIdentity(DeviceIdentity identity, PeerSession session)
    {
        var trusted = IsTrusted(identity);
        var existing = DiscoveredPeers.FirstOrDefault(peer => peer.identity.deviceID == identity.deviceID);
        var trustedPeer = TrustedPeers.FirstOrDefault(peer => peer.deviceID == identity.deviceID);
        var host = existing?.host ?? trustedPeer?.lastHost ?? session.RemoteHost;
        var port = existing?.port > 0 ? existing.port : trustedPeer?.lastPort > 0 ? trustedPeer.lastPort : session.RemoteListenPort;
        DiscoveredPeers = new ObservableCollection<DiscoveredPeer>(
            DiscoveredPeers.Where(peer => peer.identity.deviceID != identity.deviceID));
        DiscoveredPeers.Add(new DiscoveredPeer(identity, host, port, trusted));
    }

    private bool CanSend(DeviceIdentity identity) => IsTrusted(identity) && ConnectedPeerIDs.Contains(identity.deviceID);

    private bool IsTrusted(DeviceIdentity identity) =>
        TrustedPeers.Any(peer => peer.deviceID == identity.deviceID && peer.publicKey == identity.publicKey);

    private string PairingCode(DeviceIdentity identity) =>
        LocalLinkHashes.PairingCode(LocalIdentity.publicKey, identity.publicKey);

    private string SendBlockedMessage(DeviceIdentity identity) =>
        IsTrusted(identity) ? $"{identity.displayName} is disconnected." : $"Pair with {identity.displayName} before sending.";

    private void AppendMessage(ConversationMessage message)
    {
        Messages.Add(message);
        stores.SaveMessages(Messages);
        Changed?.Invoke();
    }

    private void Upsert(TransferItem item)
    {
        ReplaceTransfer(item);
        stores.SaveTransfers(Transfers);
        Changed?.Invoke();
    }

    private void ReplaceTransfer(TransferItem item)
    {
        var existing = Transfers.FirstOrDefault(transfer => transfer.id == item.id);
        if (existing is not null)
        {
            var index = Transfers.IndexOf(existing);
            Transfers[index] = item;
        }
        else
        {
            Transfers.Add(item);
        }
    }

    private void ClearEphemeralTransfers(string peerID)
    {
        foreach (var transfer in Transfers.Where(transfer => transfer.peerID == peerID && transfer.downloadedPath is null).ToList())
        {
            payloads.Remove(transfer.id);
            Transfers.Remove(transfer);
        }
        stores.SaveTransfers(Transfers);
    }

    private void ClearAllEphemeralTransfers()
    {
        foreach (var transfer in Transfers.Where(transfer => transfer.downloadedPath is null).ToList())
        {
            payloads.Remove(transfer.id);
            Transfers.Remove(transfer);
        }
        stores.SaveTransfers(Transfers);
    }

    private static string UniqueFilePath(string directory, string fileName)
    {
        var destination = Path.Combine(directory, fileName);
        if (!File.Exists(destination))
        {
            return destination;
        }

        var stem = Path.GetFileNameWithoutExtension(fileName);
        var extension = Path.GetExtension(fileName);
        for (var index = 1; index < 1000; index++)
        {
            var candidate = Path.Combine(directory, $"{stem}-{index}{extension}");
            if (!File.Exists(candidate))
            {
                return candidate;
            }
        }

        return Path.Combine(directory, $"{Guid.NewGuid()}-{fileName}");
    }

    private static bool TryParseEndpoint(string endpoint, out string host, out int port)
    {
        host = "";
        port = 53317;
        var trimmed = endpoint.Trim();
        if (string.IsNullOrWhiteSpace(trimmed))
        {
            return false;
        }

        var separator = trimmed.LastIndexOf(':');
        if (separator > 0 && int.TryParse(trimmed[(separator + 1)..], out var parsedPort))
        {
            host = trimmed[..separator].Trim().Trim('[', ']');
            port = parsedPort;
        }
        else
        {
            host = trimmed;
        }

        return !string.IsNullOrWhiteSpace(host) && port is > 0 and <= 65535;
    }

    private static void RunOnUi(Action action)
    {
        var dispatcher = System.Windows.Application.Current?.Dispatcher;
        if (dispatcher is null || dispatcher.CheckAccess())
        {
            action();
        }
        else
        {
            dispatcher.Invoke(action);
        }
    }
}

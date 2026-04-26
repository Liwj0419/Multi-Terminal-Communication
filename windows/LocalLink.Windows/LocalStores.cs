using System.IO;
using System.Text.Json;

namespace LocalLink.Windows;

public sealed class LocalStores
{
    private readonly string root;
    private readonly string identityPath;
    private readonly string trustedPath;
    private readonly string messagesPath;
    private readonly string transfersPath;

    public LocalStores()
    {
        root = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "LocalLink");
        Directory.CreateDirectory(root);
        identityPath = Path.Combine(root, "identity.json");
        trustedPath = Path.Combine(root, "trusted-peers.json");
        messagesPath = Path.Combine(root, "messages.json");
        transfersPath = Path.Combine(root, "transfers.json");
    }

    public LocalDeviceIdentity LoadOrCreateIdentity()
    {
        if (File.Exists(identityPath))
        {
            var stored = JsonSerializer.Deserialize<StoredIdentity>(
                File.ReadAllText(identityPath),
                LocalLinkJson.Options);
            if (stored is not null)
            {
                return new LocalDeviceIdentity(
                    new DeviceIdentity(
                        stored.DeviceID,
                        stored.DisplayName,
                        DevicePlatform.windows,
                        stored.PublicKey),
                    Convert.FromBase64String(stored.PrivateKey));
            }
        }

        var created = SessionCrypto.MakeIdentity(Environment.MachineName);
        SaveIdentity(created);
        return created;
    }

    public LocalDeviceIdentity UpdateDisplayName(string displayName)
    {
        var current = LoadOrCreateIdentity();
        var trimmed = string.IsNullOrWhiteSpace(displayName)
            ? current.identity.displayName
            : displayName.Trim();
        var updated = current with { identity = current.identity with { displayName = trimmed } };
        SaveIdentity(updated);
        return updated;
    }

    public List<TrustedPeer> LoadTrustedPeers() => LoadList<TrustedPeer>(trustedPath);

    public bool IsTrusted(DeviceIdentity identity) =>
        LoadTrustedPeers().Any(peer => peer.deviceID == identity.deviceID && peer.publicKey == identity.publicKey);

    public void SaveTrusted(DeviceIdentity identity)
    {
        var peers = LoadTrustedPeers()
            .Where(peer => peer.deviceID != identity.deviceID)
            .ToList();
        peers.Add(new TrustedPeer(identity.deviceID, identity.displayName, identity.platform, identity.publicKey));
        SaveList(trustedPath, peers);
    }

    public void Forget(string peerID)
    {
        SaveList(trustedPath, LoadTrustedPeers().Where(peer => peer.deviceID != peerID).ToList());
    }

    public List<ConversationMessage> LoadMessages() => LoadList<ConversationMessage>(messagesPath);

    public void SaveMessages(IEnumerable<ConversationMessage> messages) =>
        SaveList(messagesPath, messages.ToList());

    public void ClearMessages(string peerID) =>
        SaveMessages(LoadMessages().Where(message => message.peerID != peerID));

    public List<TransferItem> LoadTransfers() =>
        LoadList<TransferItem>(transfersPath)
            .Where(transfer => transfer.downloadedPath is not null && File.Exists(transfer.downloadedPath))
            .ToList();

    public void SaveTransfers(IEnumerable<TransferItem> transfers) =>
        SaveList(transfersPath, transfers.Where(transfer => transfer.downloadedPath is not null).ToList());

    public void ClearTransfers(string peerID) =>
        SaveTransfers(LoadTransfers().Where(transfer => transfer.peerID != peerID));

    private void SaveIdentity(LocalDeviceIdentity identity)
    {
        var stored = new StoredIdentity(
            identity.identity.deviceID,
            identity.identity.displayName,
            identity.identity.publicKey,
            Convert.ToBase64String(identity.privateKey));
        File.WriteAllText(identityPath, JsonSerializer.Serialize(stored, LocalLinkJson.Options));
    }

    private static List<T> LoadList<T>(string path)
    {
        if (!File.Exists(path))
        {
            return new List<T>();
        }

        return JsonSerializer.Deserialize<List<T>>(File.ReadAllText(path), LocalLinkJson.Options) ?? new List<T>();
    }

    private static void SaveList<T>(string path, List<T> values)
    {
        File.WriteAllText(path, JsonSerializer.Serialize(values, LocalLinkJson.Options));
    }

    private sealed record StoredIdentity(
        string DeviceID,
        string DisplayName,
        string PublicKey,
        string PrivateKey);
}

using System.Text.Json;
using System.Text.Json.Serialization;

namespace LocalLink.Windows;

public enum DevicePlatform
{
    iOS,
    macOS,
    android,
    windows,
    unknown
}

public enum FrameKind
{
    hello,
    pairRequest,
    pairConfirm,
    pairAccepted,
    auth,
    text,
    fileOffer,
    fileChunk,
    fileComplete,
    cancel,
    disconnect,
    error
}

public enum TransferDirection
{
    Incoming,
    Outgoing
}

public enum TransferStatus
{
    inProgress,
    complete,
    failed,
    cancelled
}

public sealed record DeviceIdentity(
    string deviceID,
    string displayName,
    DevicePlatform platform,
    string publicKey,
    int protocolVersion = 1);

public sealed record LocalDeviceIdentity(DeviceIdentity identity, byte[] privateKey);

public sealed record DiscoveredPeer(
    DeviceIdentity identity,
    string host,
    int port,
    bool isTrusted)
{
    public string Id => identity.deviceID;
    public string EndpointDescription => string.IsNullOrWhiteSpace(host) ? "Offline" : host;
}

public sealed record TrustedPeer(
    string deviceID,
    string displayName,
    DevicePlatform platform,
    string publicKey);

public sealed record ConversationMessage(
    string peerID,
    bool isOutgoing,
    string text,
    DateTimeOffset createdAt);

public sealed record TransferItem(
    Guid id,
    string peerID,
    TransferDirection direction,
    string fileName,
    string? contentType,
    long totalBytes,
    long completedBytes,
    string? checksum,
    TransferStatus status,
    string? downloadedPath)
{
    public bool IsPicture
    {
        get
        {
            var lower = fileName.ToLowerInvariant();
            return contentType?.StartsWith("image/", StringComparison.OrdinalIgnoreCase) == true ||
                lower.EndsWith(".jpg") ||
                lower.EndsWith(".jpeg") ||
                lower.EndsWith(".png") ||
                lower.EndsWith(".gif") ||
                lower.EndsWith(".webp") ||
                lower.EndsWith(".heic");
        }
    }

    public double Progress => totalBytes <= 0 ? 0 : Math.Clamp((double)completedBytes / totalBytes, 0, 1);
}

public sealed class FrameHeader
{
    public Guid id { get; set; } = Guid.NewGuid();
    [JsonConverter(typeof(JsonStringEnumConverter))]
    public FrameKind kind { get; set; }
    public string senderID { get; set; } = "";
    public string? recipientID { get; set; }
    public Guid? transferID { get; set; }
    public DateTimeOffset timestamp { get; set; } = DateTimeOffset.UtcNow;
    public Dictionary<string, string> metadata { get; set; } = new();
    public int payloadLength { get; set; }
}

public sealed record WireFrame(FrameHeader Header, byte[] Payload);

public static class LocalLinkJson
{
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = null,
        WriteIndented = false,
        Converters =
        {
            new JsonStringEnumConverter()
        }
    };
}

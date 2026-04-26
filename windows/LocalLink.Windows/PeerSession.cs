using System.Net.Sockets;
using System.Text;
using System.Text.Json;

namespace LocalLink.Windows;

public sealed class PeerSession : IDisposable
{
    private readonly TcpClient client;
    private readonly LocalDeviceIdentity local;
    private readonly CancellationTokenSource cancellation = new();
    private readonly List<byte> receiveBuffer = new();
    private readonly SemaphoreSlim sendLock = new(1, 1);
    private SessionCrypto? crypto;

    public PeerSession(TcpClient client, LocalDeviceIdentity local)
    {
        this.client = client;
        this.local = local;
    }

    public DeviceIdentity? RemoteIdentity { get; private set; }
    public string EndpointDescription => client.Client.RemoteEndPoint?.ToString() ?? "connected";

    public event Action<PeerSession, DeviceIdentity>? HelloReceived;
    public event Action<PeerSession, WireFrame, DeviceIdentity?>? FrameReceived;
    public event Action<PeerSession>? Closed;
    public event Action<Exception>? Error;

    public void Start()
    {
        _ = Task.Run(ReadLoopAsync);
        _ = SendHelloAsync();
    }

    public async Task SendHelloAsync()
    {
        var payload = JsonSerializer.SerializeToUtf8Bytes(local.identity, LocalLinkJson.Options);
        await SendAsync(FrameKind.hello, payload: payload);
    }

    public Task SendPairRequestAsync(string code) =>
        SendAsync(FrameKind.pairRequest, metadata: new Dictionary<string, string>
        {
            ["publicKey"] = local.identity.publicKey,
            ["code"] = code
        });

    public Task SendPairAcceptedAsync(string code) =>
        SendAsync(FrameKind.pairAccepted, metadata: new Dictionary<string, string> { ["code"] = code });

    public async Task SendTextAsync(string text)
    {
        var payload = Encoding.UTF8.GetBytes(text);
        await SendAsync(FrameKind.text, payload: crypto?.Seal(payload) ?? payload);
    }

    public async Task SendDataAsync(byte[] data, string fileName, string? contentType)
    {
        var transferID = Guid.NewGuid();
        var checksum = LocalLinkHashes.Sha256Hex(data);
        await SendAsync(
            FrameKind.fileOffer,
            transferID,
            new Dictionary<string, string>
            {
                ["fileName"] = fileName,
                ["contentType"] = contentType ?? "application/octet-stream",
                ["byteCount"] = data.Length.ToString(),
                ["checksum"] = checksum
            });

        const int chunkSize = 256 * 1024;
        for (var offset = 0; offset < data.Length; offset += chunkSize)
        {
            var end = Math.Min(offset + chunkSize, data.Length);
            var chunk = data[offset..end];
            await SendAsync(
                FrameKind.fileChunk,
                transferID,
                new Dictionary<string, string> { ["offset"] = offset.ToString() },
                crypto?.Seal(chunk) ?? chunk);
        }

        await SendAsync(FrameKind.fileComplete, transferID, new Dictionary<string, string> { ["checksum"] = checksum });
    }

    public Task SendDisconnectAsync() => SendAsync(FrameKind.disconnect);

    public Task SendErrorAsync(string message) =>
        SendAsync(FrameKind.error, metadata: new Dictionary<string, string> { ["message"] = message });

    public void Close(bool sendDisconnect)
    {
        if (sendDisconnect)
        {
            _ = SendDisconnectAsync();
        }

        cancellation.Cancel();
        client.Close();
        Closed?.Invoke(this);
    }

    public void Dispose()
    {
        cancellation.Cancel();
        client.Dispose();
        cancellation.Dispose();
        sendLock.Dispose();
    }

    private async Task SendAsync(
        FrameKind kind,
        Guid? transferID = null,
        Dictionary<string, string>? metadata = null,
        byte[]? payload = null)
    {
        try
        {
            var header = new FrameHeader
            {
                kind = kind,
                senderID = local.identity.deviceID,
                recipientID = RemoteIdentity?.deviceID,
                transferID = transferID,
                metadata = metadata ?? new Dictionary<string, string>()
            };
            var data = FrameCodec.Encode(new WireFrame(header, payload ?? Array.Empty<byte>()));
            await sendLock.WaitAsync(cancellation.Token);
            try
            {
                await client.GetStream().WriteAsync(data, cancellation.Token);
                await client.GetStream().FlushAsync(cancellation.Token);
            }
            finally
            {
                sendLock.Release();
            }
        }
        catch (Exception ex)
        {
            Error?.Invoke(ex);
        }
    }

    private async Task ReadLoopAsync()
    {
        var scratch = new byte[64 * 1024];
        try
        {
            var stream = client.GetStream();
            while (!cancellation.IsCancellationRequested)
            {
                var read = await stream.ReadAsync(scratch, cancellation.Token);
                if (read <= 0)
                {
                    break;
                }

                receiveBuffer.AddRange(scratch[..read]);
                DrainFrames();
            }
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception ex)
        {
            if (!cancellation.IsCancellationRequested)
            {
                Error?.Invoke(ex);
            }
        }
        finally
        {
            Closed?.Invoke(this);
        }
    }

    private void DrainFrames()
    {
        while (true)
        {
            var length = FrameCodec.NextFrameLength(receiveBuffer.ToArray());
            if (length is null || receiveBuffer.Count < length.Value)
            {
                return;
            }

            var frameBytes = receiveBuffer.Take(length.Value).ToArray();
            receiveBuffer.RemoveRange(0, length.Value);
            Handle(FrameCodec.Decode(frameBytes));
        }
    }

    private void Handle(WireFrame frame)
    {
        var clearFrame = frame;
        if ((frame.Header.kind == FrameKind.text || frame.Header.kind == FrameKind.fileChunk) && crypto is not null)
        {
            clearFrame = frame with { Payload = crypto.Open(frame.Payload) };
        }

        if (clearFrame.Header.kind == FrameKind.hello)
        {
            var identity = JsonSerializer.Deserialize<DeviceIdentity>(clearFrame.Payload, LocalLinkJson.Options);
            if (identity is not null)
            {
                RemoteIdentity = identity;
                crypto = TryMakeCrypto(identity);
                HelloReceived?.Invoke(this, identity);
            }
        }

        FrameReceived?.Invoke(this, clearFrame, RemoteIdentity);
    }

    private SessionCrypto? TryMakeCrypto(DeviceIdentity identity)
    {
        try
        {
            return new SessionCrypto(local.privateKey, identity.publicKey);
        }
        catch
        {
            return null;
        }
    }
}

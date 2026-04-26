using System.Buffers.Binary;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;

namespace LocalLink.Windows;

public sealed class MdnsPeerService : IDisposable
{
    private const string ServiceType = "_locallink._tcp.local";
    private static readonly IPEndPoint MdnsEndpoint = new(IPAddress.Parse("224.0.0.251"), 5353);

    private readonly LocalDeviceIdentity local;
    private readonly Func<DeviceIdentity, bool> isTrusted;
    private readonly CancellationTokenSource cancellation = new();
    private readonly Dictionary<string, PartialPeer> partialPeers = new();

    private TcpListener? listener;
    private UdpClient? udp;
    private int port;

    public MdnsPeerService(LocalDeviceIdentity local, Func<DeviceIdentity, bool> isTrusted)
    {
        this.local = local;
        this.isTrusted = isTrusted;
    }

    public event Action<List<DiscoveredPeer>>? PeersChanged;
    public event Action<PeerSession>? SessionAccepted;
    public event Action<Exception>? Error;

    public void Start()
    {
        listener = new TcpListener(IPAddress.Any, 0);
        listener.Start();
        port = ((IPEndPoint)listener.LocalEndpoint).Port;

        udp = new UdpClient(AddressFamily.InterNetwork)
        {
            EnableBroadcast = true,
            MulticastLoopback = true
        };
        udp.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
        udp.Client.Bind(new IPEndPoint(IPAddress.Any, 5353));
        udp.JoinMulticastGroup(MdnsEndpoint.Address);

        _ = Task.Run(AcceptLoopAsync);
        _ = Task.Run(MdnsLoopAsync);
        _ = Task.Run(QueryLoopAsync);
    }

    public void Stop()
    {
        cancellation.Cancel();
        try { listener?.Stop(); } catch { }
        try { udp?.DropMulticastGroup(MdnsEndpoint.Address); } catch { }
        udp?.Dispose();
    }

    public PeerSession Connect(DiscoveredPeer peer)
    {
        var client = new TcpClient();
        client.Connect(peer.host, peer.port);
        var session = new PeerSession(client, local);
        session.Start();
        return session;
    }

    public void Dispose()
    {
        Stop();
        cancellation.Dispose();
    }

    private async Task AcceptLoopAsync()
    {
        try
        {
            while (!cancellation.IsCancellationRequested && listener is not null)
            {
                var client = await listener.AcceptTcpClientAsync(cancellation.Token);
                var session = new PeerSession(client, local);
                SessionAccepted?.Invoke(session);
                session.Start();
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
    }

    private async Task MdnsLoopAsync()
    {
        if (udp is null)
        {
            return;
        }

        while (!cancellation.IsCancellationRequested)
        {
            try
            {
                var result = await udp.ReceiveAsync(cancellation.Token);
                HandleMdnsPacket(result.Buffer, result.RemoteEndPoint);
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
        }
    }

    private async Task QueryLoopAsync()
    {
        while (!cancellation.IsCancellationRequested)
        {
            try
            {
                Send(QueryPacket());
                Send(AdvertisementPacket());
                await Task.Delay(TimeSpan.FromSeconds(5), cancellation.Token);
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
        }
    }

    private void HandleMdnsPacket(byte[] packet, IPEndPoint remote)
    {
        if (packet.Length < 12)
        {
            return;
        }

        var reader = new DnsReader(packet);
        reader.Skip(4);
        var questionCount = reader.ReadUInt16();
        var answerCount = reader.ReadUInt16();
        var authorityCount = reader.ReadUInt16();
        var additionalCount = reader.ReadUInt16();
        var totalRecords = answerCount + authorityCount + additionalCount;

        var shouldAnswer = false;
        for (var i = 0; i < questionCount; i++)
        {
            var name = reader.ReadName();
            var type = reader.ReadUInt16();
            reader.Skip(2);
            if (type == 12 && IsServiceName(name))
            {
                shouldAnswer = true;
            }
        }

        if (shouldAnswer)
        {
            Send(AdvertisementPacket());
        }

        for (var i = 0; i < totalRecords && !reader.IsDone; i++)
        {
            var name = reader.ReadName();
            var type = reader.ReadUInt16();
            reader.Skip(2);
            reader.Skip(4);
            var length = reader.ReadUInt16();
            var dataStart = reader.Offset;

            switch (type)
            {
                case 12:
                    var instanceName = reader.ReadName();
                    if (IsServiceName(name))
                    {
                        EnsurePartial(instanceName).Instance = instanceName;
                    }
                    break;
                case 33:
                    reader.Skip(4);
                    var srvPort = reader.ReadUInt16();
                    var hostName = reader.ReadName();
                    var srv = EnsurePartial(name);
                    srv.Port = srvPort;
                    srv.HostName = hostName;
                    break;
                case 16:
                    var end = dataStart + length;
                    var txt = EnsurePartial(name);
                    while (reader.Offset < end)
                    {
                        var size = reader.ReadByte();
                        if (size <= 0 || reader.Offset + size > end)
                        {
                            break;
                        }

                        var text = Encoding.UTF8.GetString(packet, reader.Offset, size);
                        reader.Skip(size);
                        var separator = text.IndexOf('=');
                        if (separator > 0)
                        {
                            txt.Attributes[text[..separator]] = text[(separator + 1)..];
                        }
                    }
                    break;
                case 1:
                    if (length == 4)
                    {
                        var ip = new IPAddress(packet.AsSpan(reader.Offset, 4));
                        foreach (var partial in partialPeers.Values.Where(peer => peer.HostName == name))
                        {
                            partial.Host = ip.ToString();
                        }
                    }
                    reader.Skip(length);
                    break;
                default:
                    reader.Skip(length);
                    break;
            }
        }

        PublishPeers();
    }

    private PartialPeer EnsurePartial(string instanceName)
    {
        if (!partialPeers.TryGetValue(instanceName, out var partial))
        {
            partial = new PartialPeer { Instance = instanceName };
            partialPeers[instanceName] = partial;
        }

        return partial;
    }

    private void PublishPeers()
    {
        var peers = partialPeers.Values
            .Select(ToPeer)
            .Where(peer => peer is not null)
            .Cast<DiscoveredPeer>()
            .GroupBy(peer => peer.identity.deviceID)
            .Select(group => group.Last())
            .Where(peer => peer.identity.deviceID != local.identity.deviceID)
            .ToList();
        PeersChanged?.Invoke(peers);
    }

    private DiscoveredPeer? ToPeer(PartialPeer partial)
    {
        if (!partial.Attributes.TryGetValue("id", out var id) ||
            !partial.Attributes.TryGetValue("publicKey", out var publicKey) ||
            string.IsNullOrWhiteSpace(partial.Host) ||
            partial.Port <= 0)
        {
            return null;
        }

        var platformText = partial.Attributes.GetValueOrDefault("platform", "unknown");
        var platform = Enum.TryParse<DevicePlatform>(platformText, true, out var parsed) ? parsed : DevicePlatform.unknown;
        var identity = new DeviceIdentity(
            id,
            partial.Attributes.GetValueOrDefault("name", partial.Instance),
            platform,
            publicKey,
            int.TryParse(partial.Attributes.GetValueOrDefault("version"), out var version) ? version : 1);
        return new DiscoveredPeer(identity, partial.Host, partial.Port, isTrusted(identity));
    }

    private byte[] QueryPacket()
    {
        var writer = new DnsWriter();
        writer.WriteUInt16(0);
        writer.WriteUInt16(0);
        writer.WriteUInt16(1);
        writer.WriteUInt16(0);
        writer.WriteUInt16(0);
        writer.WriteUInt16(0);
        writer.WriteName(ServiceType);
        writer.WriteUInt16(12);
        writer.WriteUInt16(1);
        return writer.ToArray();
    }

    private byte[] AdvertisementPacket()
    {
        var instance = $"{Sanitize(local.identity.displayName)}-{local.identity.deviceID[..8]}";
        var instanceName = $"{instance}.{ServiceType}";
        var hostName = $"{local.identity.deviceID.Replace("-", "").ToLowerInvariant()}.local";
        var address = LocalIPv4Address();
        var writer = new DnsWriter();
        writer.WriteUInt16(0);
        writer.WriteUInt16(0x8400);
        writer.WriteUInt16(0);
        writer.WriteUInt16(4);
        writer.WriteUInt16(0);
        writer.WriteUInt16(0);

        writer.WriteRecord(ServiceType, 12, record => record.WriteName(instanceName));
        writer.WriteRecord(instanceName, 33, record =>
        {
            record.WriteUInt16(0);
            record.WriteUInt16(0);
            record.WriteUInt16((ushort)port);
            record.WriteName(hostName);
        });
        writer.WriteRecord(instanceName, 16, record =>
        {
            record.WriteText($"id={local.identity.deviceID}");
            record.WriteText($"name={local.identity.displayName}");
            record.WriteText("platform=windows");
            record.WriteText($"version={local.identity.protocolVersion}");
            record.WriteText($"publicKey={local.identity.publicKey}");
        });
        writer.WriteRecord(hostName, 1, record => record.WriteBytes(address.GetAddressBytes()));
        return writer.ToArray();
    }

    private void Send(byte[] packet)
    {
        udp?.Send(packet, packet.Length, MdnsEndpoint);
    }

    private static bool IsServiceName(string name) =>
        string.Equals(name.TrimEnd('.'), ServiceType, StringComparison.OrdinalIgnoreCase);

    private static string Sanitize(string value)
    {
        var cleaned = new string(value.Where(ch => char.IsLetterOrDigit(ch) || ch is '-' or '_').ToArray());
        return string.IsNullOrWhiteSpace(cleaned) ? "LocalLink" : cleaned;
    }

    private static IPAddress LocalIPv4Address()
    {
        foreach (var network in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (network.OperationalStatus != OperationalStatus.Up ||
                network.NetworkInterfaceType == NetworkInterfaceType.Loopback)
            {
                continue;
            }

            foreach (var address in network.GetIPProperties().UnicastAddresses)
            {
                if (address.Address.AddressFamily == AddressFamily.InterNetwork)
                {
                    return address.Address;
                }
            }
        }

        return IPAddress.Loopback;
    }

    private sealed class PartialPeer
    {
        public string Instance { get; set; } = "";
        public string HostName { get; set; } = "";
        public string Host { get; set; } = "";
        public int Port { get; set; }
        public Dictionary<string, string> Attributes { get; } = new();
    }

    private sealed class DnsReader
    {
        private readonly byte[] packet;

        public DnsReader(byte[] packet)
        {
            this.packet = packet;
        }

        public int Offset { get; private set; }
        public bool IsDone => Offset >= packet.Length;

        public byte ReadByte() => packet[Offset++];
        public ushort ReadUInt16()
        {
            var value = BinaryPrimitives.ReadUInt16BigEndian(packet.AsSpan(Offset, 2));
            Offset += 2;
            return value;
        }

        public void Skip(int count) => Offset = Math.Min(packet.Length, Offset + count);

        public string ReadName()
        {
            var labels = new List<string>();
            var cursor = Offset;
            var jumped = false;

            while (cursor < packet.Length)
            {
                var length = packet[cursor++];
                if (length == 0)
                {
                    break;
                }

                if ((length & 0xC0) == 0xC0)
                {
                    var pointer = ((length & 0x3F) << 8) | packet[cursor++];
                    if (!jumped)
                    {
                        Offset = cursor;
                    }
                    cursor = pointer;
                    jumped = true;
                    continue;
                }

                labels.Add(Encoding.UTF8.GetString(packet, cursor, length));
                cursor += length;
            }

            if (!jumped)
            {
                Offset = cursor;
            }

            return string.Join(".", labels);
        }
    }

    private sealed class DnsWriter
    {
        private readonly MemoryStream stream = new();

        public void WriteUInt16(ushort value)
        {
            Span<byte> buffer = stackalloc byte[2];
            BinaryPrimitives.WriteUInt16BigEndian(buffer, value);
            stream.Write(buffer);
        }

        public void WriteBytes(byte[] bytes) => stream.Write(bytes);

        public void WriteName(string name)
        {
            foreach (var label in name.TrimEnd('.').Split('.'))
            {
                var bytes = Encoding.UTF8.GetBytes(label);
                stream.WriteByte((byte)bytes.Length);
                stream.Write(bytes);
            }
            stream.WriteByte(0);
        }

        public void WriteText(string text)
        {
            var bytes = Encoding.UTF8.GetBytes(text);
            stream.WriteByte((byte)Math.Min(bytes.Length, 255));
            stream.Write(bytes, 0, Math.Min(bytes.Length, 255));
        }

        public void WriteRecord(string name, ushort type, Action<DnsWriter> writeData)
        {
            WriteName(name);
            WriteUInt16(type);
            WriteUInt16(1);
            WriteUInt16(0);
            WriteUInt16(120);

            var record = new DnsWriter();
            writeData(record);
            var data = record.ToArray();
            WriteUInt16((ushort)data.Length);
            WriteBytes(data);
        }

        public byte[] ToArray() => stream.ToArray();
    }
}

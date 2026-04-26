using System.Buffers.Binary;
using System.Text.Json;

namespace LocalLink.Windows;

public static class FrameCodec
{
    public const int MaxHeaderBytes = 64 * 1024;
    public const int MaxPayloadBytes = 8 * 1024 * 1024;

    public static byte[] Encode(WireFrame frame)
    {
        frame.Header.payloadLength = frame.Payload.Length;
        if (frame.Payload.Length > MaxPayloadBytes)
        {
            throw new InvalidOperationException("Payload is too large.");
        }

        var headerBytes = JsonSerializer.SerializeToUtf8Bytes(frame.Header, LocalLinkJson.Options);
        if (headerBytes.Length is <= 0 or > MaxHeaderBytes)
        {
            throw new InvalidOperationException("Header is invalid.");
        }

        var output = new byte[4 + headerBytes.Length + frame.Payload.Length];
        BinaryPrimitives.WriteUInt32BigEndian(output.AsSpan(0, 4), (uint)headerBytes.Length);
        Buffer.BlockCopy(headerBytes, 0, output, 4, headerBytes.Length);
        Buffer.BlockCopy(frame.Payload, 0, output, 4 + headerBytes.Length, frame.Payload.Length);
        return output;
    }

    public static int? NextFrameLength(ReadOnlySpan<byte> buffer)
    {
        if (buffer.Length < 4)
        {
            return null;
        }

        var headerLength = (int)BinaryPrimitives.ReadUInt32BigEndian(buffer[..4]);
        if (headerLength is <= 0 or > MaxHeaderBytes)
        {
            throw new InvalidOperationException("Header length is invalid.");
        }

        if (buffer.Length < 4 + headerLength)
        {
            return null;
        }

        var header = JsonSerializer.Deserialize<FrameHeader>(
            buffer.Slice(4, headerLength),
            LocalLinkJson.Options) ?? throw new InvalidOperationException("Header is invalid.");

        if (header.payloadLength is < 0 or > MaxPayloadBytes)
        {
            throw new InvalidOperationException("Payload length is invalid.");
        }

        return 4 + headerLength + header.payloadLength;
    }

    public static WireFrame Decode(ReadOnlySpan<byte> data)
    {
        if (data.Length < 4)
        {
            throw new InvalidOperationException("Frame is too small.");
        }

        var headerLength = (int)BinaryPrimitives.ReadUInt32BigEndian(data[..4]);
        if (headerLength is <= 0 or > MaxHeaderBytes)
        {
            throw new InvalidOperationException("Header length is invalid.");
        }

        if (data.Length < 4 + headerLength)
        {
            throw new InvalidOperationException("Frame is incomplete.");
        }

        var header = JsonSerializer.Deserialize<FrameHeader>(
            data.Slice(4, headerLength),
            LocalLinkJson.Options) ?? throw new InvalidOperationException("Header is invalid.");

        if (header.payloadLength is < 0 or > MaxPayloadBytes)
        {
            throw new InvalidOperationException("Payload length is invalid.");
        }

        var fullLength = 4 + headerLength + header.payloadLength;
        if (data.Length < fullLength)
        {
            throw new InvalidOperationException("Payload is incomplete.");
        }

        return new WireFrame(header, data.Slice(4 + headerLength, header.payloadLength).ToArray());
    }
}

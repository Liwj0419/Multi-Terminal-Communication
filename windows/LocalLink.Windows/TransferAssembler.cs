namespace LocalLink.Windows;

public sealed class TransferAssembler
{
    private readonly Dictionary<Guid, PendingTransfer> pending = new();

    public TransferItem? AcceptOffer(string peerID, WireFrame frame)
    {
        if (frame.Header.transferID is not Guid transferID)
        {
            return null;
        }

        var metadata = frame.Header.metadata;
        var fileName = metadata.GetValueOrDefault("fileName", "File");
        var contentType = metadata.GetValueOrDefault("contentType");
        var totalBytes = long.TryParse(metadata.GetValueOrDefault("byteCount"), out var bytes) ? bytes : 0;
        var checksum = metadata.GetValueOrDefault("checksum");

        pending[transferID] = new PendingTransfer(peerID, fileName, contentType, totalBytes, checksum);
        return new TransferItem(
            transferID,
            peerID,
            TransferDirection.Incoming,
            fileName,
            contentType,
            totalBytes,
            0,
            checksum,
            TransferStatus.inProgress,
            null);
    }

    public TransferItem AppendChunk(WireFrame frame)
    {
        if (frame.Header.transferID is not Guid transferID || !pending.TryGetValue(transferID, out var transfer))
        {
            throw new InvalidOperationException("Transfer is missing.");
        }

        var offset = long.TryParse(frame.Header.metadata.GetValueOrDefault("offset"), out var value) ? value : transfer.Bytes.Count;
        if (offset != transfer.Bytes.Count)
        {
            throw new InvalidOperationException("File chunk offset is invalid.");
        }

        transfer.Bytes.AddRange(frame.Payload);
        return transfer.ToItem(transferID, TransferStatus.inProgress);
    }

    public (TransferItem Transfer, byte[] Data) Complete(WireFrame frame)
    {
        if (frame.Header.transferID is not Guid transferID || !pending.TryGetValue(transferID, out var transfer))
        {
            throw new InvalidOperationException("Transfer is missing.");
        }

        var data = transfer.Bytes.ToArray();
        var expectedChecksum = frame.Header.metadata.GetValueOrDefault("checksum") ?? transfer.Checksum;
        if (!string.IsNullOrWhiteSpace(expectedChecksum) &&
            !string.Equals(LocalLinkHashes.Sha256Hex(data), expectedChecksum, StringComparison.OrdinalIgnoreCase))
        {
            pending.Remove(transferID);
            throw new InvalidOperationException("File checksum did not match.");
        }

        pending.Remove(transferID);
        return (transfer.ToItem(transferID, TransferStatus.complete), data);
    }

    private sealed class PendingTransfer
    {
        public PendingTransfer(string peerID, string fileName, string? contentType, long totalBytes, string? checksum)
        {
            PeerID = peerID;
            FileName = fileName;
            ContentType = contentType;
            TotalBytes = totalBytes;
            Checksum = checksum;
        }

        public string PeerID { get; }
        public string FileName { get; }
        public string? ContentType { get; }
        public long TotalBytes { get; }
        public string? Checksum { get; }
        public List<byte> Bytes { get; } = new();

        public TransferItem ToItem(Guid id, TransferStatus status) => new(
            id,
            PeerID,
            TransferDirection.Incoming,
            FileName,
            ContentType,
            TotalBytes,
            Bytes.Count,
            Checksum,
            status,
            null);
    }
}

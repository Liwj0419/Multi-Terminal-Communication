using System.Security.Cryptography;
using Org.BouncyCastle.Crypto.Agreement;
using Org.BouncyCastle.Crypto.Digests;
using Org.BouncyCastle.Crypto.Generators;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Security;
using BouncyCastleChaCha20Poly1305 = Org.BouncyCastle.Crypto.Modes.ChaCha20Poly1305;

namespace LocalLink.Windows;

public sealed class SessionCrypto
{
    private readonly byte[] key;

    public SessionCrypto(byte[] localPrivateKey, string remotePublicKeyBase64)
    {
        var privateKey = new X25519PrivateKeyParameters(localPrivateKey, 0);
        var publicKey = new X25519PublicKeyParameters(Convert.FromBase64String(remotePublicKeyBase64), 0);
        var agreement = new X25519Agreement();
        agreement.Init(privateKey);

        var shared = new byte[agreement.AgreementSize];
        agreement.CalculateAgreement(publicKey, shared, 0);

        key = new byte[32];
        var hkdf = new HkdfBytesGenerator(new Sha256Digest());
        hkdf.Init(new HkdfParameters(
            shared,
            "LocalLink-v1"u8.ToArray(),
            "frames"u8.ToArray()));
        hkdf.GenerateBytes(key, 0, key.Length);
    }

    public byte[] Seal(byte[] payload)
    {
        var nonce = RandomNumberGenerator.GetBytes(12);
        var cipher = new BouncyCastleChaCha20Poly1305();
        cipher.Init(true, new AeadParameters(new KeyParameter(key), 128, nonce));
        var encrypted = new byte[cipher.GetOutputSize(payload.Length)];
        var len = cipher.ProcessBytes(payload, 0, payload.Length, encrypted, 0);
        cipher.DoFinal(encrypted, len);
        return nonce.Concat(encrypted).ToArray();
    }

    public byte[] Open(byte[] sealedPayload)
    {
        if (sealedPayload.Length < 12)
        {
            throw new InvalidOperationException("Encrypted payload is too small.");
        }

        var nonce = sealedPayload[..12];
        var encrypted = sealedPayload[12..];
        var cipher = new BouncyCastleChaCha20Poly1305();
        cipher.Init(false, new AeadParameters(new KeyParameter(key), 128, nonce));
        var output = new byte[cipher.GetOutputSize(encrypted.Length)];
        var len = cipher.ProcessBytes(encrypted, 0, encrypted.Length, output, 0);
        var finalLen = cipher.DoFinal(output, len);
        return output[..(len + finalLen)];
    }

    public static LocalDeviceIdentity MakeIdentity(string displayName)
    {
        var privateKey = new X25519PrivateKeyParameters(new SecureRandom());
        var privateBytes = new byte[32];
        privateKey.Encode(privateBytes, 0);
        var publicBytes = new byte[32];
        privateKey.GeneratePublicKey().Encode(publicBytes, 0);
        var identity = new DeviceIdentity(
            Guid.NewGuid().ToString().ToUpperInvariant(),
            displayName,
            DevicePlatform.windows,
            Convert.ToBase64String(publicBytes));
        return new LocalDeviceIdentity(identity, privateBytes);
    }
}

public static class LocalLinkHashes
{
    public static string Sha256Hex(byte[] data) =>
        Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();

    public static string PairingCode(string localPublicKey, string remotePublicKey)
    {
        var joined = string.Join("|", new[] { localPublicKey, remotePublicKey }.Order(StringComparer.Ordinal));
        var digest = SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(joined));
        long value = 0;
        for (var i = 0; i < 4; i++)
        {
            value = (value << 8) | digest[i];
        }

        return (value % 1_000_000).ToString("D6");
    }
}

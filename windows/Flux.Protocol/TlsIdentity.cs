using System.Security.Cryptography.X509Certificates;

namespace Flux.Protocol;

public static class TlsIdentity
{
    // Schannel cannot use ephemeral private keys. UserKeySet imports a temporary
    // OS-backed user key; without PersistKeySet its container is cleaned on dispose.
    // The durable identity remains the caller's DPAPI-protected PFX, not a new key.
    public static X509Certificate2 Load(byte[] pfx) => X509CertificateLoader.LoadPkcs12(
        pfx, "", OperatingSystem.IsWindows()
            ? X509KeyStorageFlags.UserKeySet : X509KeyStorageFlags.EphemeralKeySet);
}

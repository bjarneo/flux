using System.Net.Security;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;

namespace FluxKit;

// TLS for Flux links and payloads. Both sides present a self-signed
// certificate. The handshake accepts any certificate. The link code checks
// the peer certificate against the device ID and the pinned certificate after
// the handshake.
public sealed class FluxTls(LocalCertificate local)
{
    // Only TLS 1.2, like the Mac and Android apps. A TLS 1.3 server sends
    // session tickets after the handshake. fluxd does not read a tunnel that
    // it writes a payload to, so its close with the unread tickets resets the
    // connection and drops the end of the payload.
    const SslProtocols Protocols = SslProtocols.Tls12;

    public LocalCertificate Local { get; } = local;

    // Runs the handshake as the TLS server. The client must present a
    // certificate.
    public async Task<SslStream> ServerAsync(Stream inner, CancellationToken ct)
    {
        var ssl = new SslStream(inner, false);
        try
        {
            await ssl.AuthenticateAsServerAsync(new SslServerAuthenticationOptions
            {
                ServerCertificate = Local.Certificate,
                ClientCertificateRequired = true,
                EnabledSslProtocols = Protocols,
                CertificateRevocationCheckMode = X509RevocationMode.NoCheck,
                RemoteCertificateValidationCallback = (_, cert, _, _) => cert is not null,
            }, ct).ConfigureAwait(false);
            return ssl;
        }
        catch
        {
            await ssl.DisposeAsync().ConfigureAwait(false);
            throw;
        }
    }

    // Runs the handshake as the TLS client with the certificate of this device.
    public async Task<SslStream> ClientAsync(Stream inner, string targetHost, CancellationToken ct)
    {
        var ssl = new SslStream(inner, false);
        try
        {
            await ssl.AuthenticateAsClientAsync(new SslClientAuthenticationOptions
            {
                TargetHost = targetHost,
                ClientCertificates = [Local.Certificate],
                // Schannel sends a self-signed client certificate only when
                // the selection names it.
                LocalCertificateSelectionCallback = (_, _, _, _, _) => Local.Certificate,
                EnabledSslProtocols = Protocols,
                CertificateRevocationCheckMode = X509RevocationMode.NoCheck,
                RemoteCertificateValidationCallback = (_, cert, _, _) => cert is not null,
            }, ct).ConfigureAwait(false);
            return ssl;
        }
        catch
        {
            await ssl.DisposeAsync().ConfigureAwait(false);
            throw;
        }
    }

    // The DER bytes of the certificate that the TLS peer presented.
    public static byte[]? PeerCertificate(SslStream ssl) => ssl.RemoteCertificate?.GetRawCertData();
}

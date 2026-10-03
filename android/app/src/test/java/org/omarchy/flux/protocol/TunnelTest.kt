package org.omarchy.flux.protocol

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.omarchy.flux.net.ConnectedSocketFactory
import org.omarchy.flux.net.PAYLOAD_PORTS
import org.omarchy.flux.net.Tls
import org.omarchy.flux.net.Tunnel
import org.omarchy.flux.net.WrongPeerException
import java.io.ByteArrayOutputStream
import java.net.InetAddress
import java.net.Socket
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

class TunnelTest {
    @Test
    fun parsesTunnelPayload() {
        val line = """{"id":1,"type":"flux.share.request","body":{"filename":"a.jpg"},"payloadSize":42,"payloadTransferInfo":{"tunnel":"tok-1"}}"""
        val p = Packet.parse(line)!!
        assertTrue(p.hasPayload)
        assertEquals(0, p.payloadPort)
        assertEquals("tok-1", p.payloadTunnel)
        assertEquals(42L, p.payloadSize)
    }

    @Test
    fun incomingPortIsNoPayload() {
        // The computer sends each payload through a tunnel, so the parse ignores a port.
        val both = Packet.parse("""{"id":1,"type":"flux.share.request","body":{},"payloadSize":5,"payloadTransferInfo":{"port":1740,"tunnel":"x"}}""")!!
        assertEquals(0, both.payloadPort)
        assertEquals("x", both.payloadTunnel)
        val port = Packet.parse("""{"id":1,"type":"flux.share.request","body":{},"payloadSize":5,"payloadTransferInfo":{"port":1740}}""")!!
        assertEquals(0, port.payloadPort)
        assertFalse(port.hasPayload)
    }

    @Test
    fun tunnelPayloadRoundTrip() {
        val p = Packet(Types.SHARE, bodyOf("filename" to "b"), id = 7, payloadSize = 9, payloadTunnel = "abc")
        val q = Packet.parse(p.serialize())!!
        assertEquals("abc", q.payloadTunnel)
        assertEquals(9L, q.payloadSize)
    }

    @Test
    fun emptyTunnelIsNoPayload() {
        val p = Packet.parse("""{"id":1,"type":"flux.share.request","body":{},"payloadSize":5,"payloadTransferInfo":{"tunnel":""}}""")!!
        assertFalse(p.hasPayload)
    }

    @Test
    fun tunnelAnswers() {
        val ready = Packet.parse(TunnelPackets.ready("t", 1745).serialize())!!
        assertEquals(Types.FLUX_TUNNEL, ready.type)
        assertEquals("t", ready.string("id"))
        assertEquals(1745, ready.int("port"))
        assertFalse(ready.has("error"))
        val failed = Packet.parse(TunnelPackets.failed("t", "no free port").serialize())!!
        assertEquals("no free port", failed.string("error"))
        assertFalse(failed.has("port"))
    }

    @Test
    fun capabilitiesListTunnel() {
        assertTrue(Types.FLUX_TUNNEL in INCOMING)
        assertTrue(Types.FLUX_TUNNEL in OUTGOING)
    }

    private fun sftp(body: String) = SftpOffer.parse(Packet.parse("""{"id":1,"type":"flux.sftp","body":$body}""")!!)

    @Test
    fun sftpOffers() {
        val offer = sftp("""{"tunnel":"s1","user":"flux","password":"pw","path":"/home/u","multiPaths":["/home/u","/home/u/Pictures"],"pathNames":["Home","Pictures"]}""")!!
        assertEquals("s1", offer.tunnel)
        assertEquals("flux", offer.user)
        assertEquals("pw", offer.password)
        assertEquals(listOf("Home" to "/home/u", "Pictures" to "/home/u/Pictures"), offer.roots)

        assertNull(sftp("""{"errorMessage":"no"}"""))
        // An offer without a tunnel has no way to connect.
        assertNull(sftp("""{"ip":"192.168.1.5","port":12070,"user":"flux","password":"pw","path":"/","multiPaths":["/"],"pathNames":["Home"]}"""))
        assertNull(sftp("""{"tunnel":"","user":"flux","password":"pw","multiPaths":["/"],"pathNames":["Home"]}"""))
        // The root lists must be present and have the same length.
        assertNull(sftp("""{"tunnel":"s1","user":"flux","password":"pw","path":"/"}"""))
        assertNull(sftp("""{"tunnel":"s1","user":"flux","password":"pw","path":"/","multiPaths":["/","/tmp"],"pathNames":["Home"]}"""))
        assertNull(sftp("""{"tunnel":"s1","user":"flux","multiPaths":["/"],"pathNames":["Home"]}"""))
    }

    private val phone = LocalCertificate.generate("0123456789abcdef0123456789abcdef")
    private val pc = LocalCertificate.generate("fedcba9876543210fedcba9876543210")

    /** Plays the computer: waits for flux.tunnel, connects as TLS client, and runs [body]. */
    private fun computer(cert: LocalCertificate, answers: ArrayBlockingQueue<Packet>, body: (javax.net.ssl.SSLSocket) -> Unit) = thread {
        val ready = answers.poll(5, TimeUnit.SECONDS) ?: return@thread
        val port = ready.int("port") ?: return@thread
        val ssl = runCatching { Tls(cert).wrap(Socket(InetAddress.getLoopbackAddress(), port), server = false) }.getOrNull() ?: return@thread
        runCatching { body(ssl) }
        runCatching { ssl.close() }
    }

    @Test
    fun receivesPayloadThroughTunnel() {
        val data = ByteArray(200_000) { (it % 251).toByte() }
        val answers = ArrayBlockingQueue<Packet>(1)
        val pcThread = computer(pc, answers) { ssl ->
            assertArrayEquals(phone.certificate.encoded, Tls.peerCertificate(ssl)!!.encoded)
            ssl.outputStream.write(data)
            ssl.outputStream.flush()
        }
        val out = ByteArrayOutputStream()
        Tunnel.receive(Tls(phone), pc.certificate, "tok", data.size.toLong(), out, announce = { answers.put(it) })
        pcThread.join(5000)
        assertArrayEquals(data, out.toByteArray())
    }

    @Test
    fun rejectsWrongComputer() {
        val stranger = LocalCertificate.generate("00000000000000000000000000000000")
        val answers = ArrayBlockingQueue<Packet>(1)
        val t = computer(stranger, answers) { it.outputStream.write(1) }
        val result = runCatching {
            Tunnel.accept(Tls(phone), pc.certificate, "tok", announce = { answers.put(it) }, timeoutMs = 1500)
        }
        t.join(5000)
        assertTrue(result.exceptionOrNull() is WrongPeerException)
    }

    @Test
    fun strangerFirstDoesNotStopTransfer() {
        // A stranger connects before the computer. Its connection closes,
        // and the computer still gets the tunnel.
        val stranger = LocalCertificate.generate("00000000000000000000000000000000")
        val ports = ArrayBlockingQueue<Packet>(2)
        val answers = ArrayBlockingQueue<Packet>(1)
        val decoy = thread {
            val ready = ports.poll(5, TimeUnit.SECONDS) ?: return@thread
            runCatching { Tls(stranger).wrap(Socket(InetAddress.getLoopbackAddress(), ready.int("port")!!), server = false).close() }
            answers.put(ready)
        }
        val data = ByteArray(1000) { it.toByte() }
        val pcThread = computer(pc, answers) { ssl ->
            ssl.outputStream.write(data)
            ssl.outputStream.flush()
        }
        val out = ByteArrayOutputStream()
        Tunnel.receive(Tls(phone), pc.certificate, "tok", data.size.toLong(), out, announce = { ports.put(it) })
        decoy.join(5000)
        pcThread.join(5000)
        assertArrayEquals(data, out.toByteArray())
    }

    @Test
    fun refusesOtherAddress() {
        // Only the address of the link can connect, so the computer at
        // 127.0.0.1 is refused before the handshake when the link is elsewhere.
        val answers = ArrayBlockingQueue<Packet>(1)
        val t = computer(pc, answers) { it.outputStream.write(1) }
        val result = runCatching {
            Tunnel.accept(Tls(phone), pc.certificate, "tok", announce = { answers.put(it) }, timeoutMs = 1500, peer = InetAddress.getByName("192.0.2.1"))
        }
        t.join(5000)
        assertTrue(result.exceptionOrNull() is WrongPeerException)
    }

    @Test
    fun sshUsesTunnelSocket() {
        // sshj takes the connected socket and opens no connection of its
        // own, so no other app can take the session.
        val server = java.net.ServerSocket(0, 1, InetAddress.getLoopbackAddress())
        val got = ArrayBlockingQueue<String>(1)
        val peer = thread {
            server.accept().use { s ->
                s.soTimeout = 5000
                s.getOutputStream().write("SSH-2.0-test\r\n".toByteArray())
                s.getOutputStream().flush()
                val line = StringBuilder()
                while (true) {
                    val b = s.getInputStream().read()
                    if (b < 0 || b == '\n'.code) break
                    line.append(b.toChar())
                }
                got.put(line.toString())
            }
        }
        val socket = Socket(InetAddress.getLoopbackAddress(), server.localPort)
        val client = net.schmizz.sshj.SSHClient(net.schmizz.sshj.DefaultConfig())
        client.addHostKeyVerifier(net.schmizz.sshj.transport.verification.PromiscuousVerifier())
        client.socketFactory = ConnectedSocketFactory(socket)
        runCatching { client.connect("computer", 22) }
        runCatching { client.disconnect() }
        peer.join(5000)
        server.close()
        assertTrue(got.poll(5, TimeUnit.SECONDS)!!.startsWith("SSH-2.0-"))
    }

    @Test
    fun timesOutWithoutComputer() {
        var announced: Packet? = null
        val result = runCatching { Tunnel.accept(Tls(phone), pc.certificate, "tok", announce = { announced = it }, timeoutMs = 300) }
        assertTrue(result.isFailure)
        val port = announced!!.int("port")!!
        assertTrue(port in PAYLOAD_PORTS)
    }
}

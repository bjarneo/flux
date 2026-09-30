package org.omarchy.flux.net

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException
import java.io.InputStream
import java.net.InetAddress
import java.net.SocketTimeoutException

/** The line limits of a link, and the address checks of the listeners. */
class LinkTest {
    private fun stream(s: String) = s.toByteArray().inputStream()

    @Test
    fun unpairedLineLimit() {
        val long = "x".repeat(MAX_UNPAIRED_LINE + 1) + "\n"
        val result = runCatching { LineReader(stream(long)).next { MAX_UNPAIRED_LINE } }
        assertTrue("a device that is not paired cannot send a long line", result.exceptionOrNull() is IOException)
        assertEquals(MAX_UNPAIRED_LINE + 1, LineReader(stream(long)).next { MAX_LINE }!!.length)
        val short = "y".repeat(MAX_UNPAIRED_LINE)
        assertEquals(short, LineReader(stream("$short\n")).next { MAX_UNPAIRED_LINE })
    }

    @Test
    fun skipDropsALongLine() {
        val long = "x".repeat(MAX_UNPAIRED_LINE + 1)
        var asked = 0
        val reader = LineReader(stream("$long\n{\"a\":1}\n$long"))
        assertEquals("", reader.next(skip = { asked++; true }) { MAX_UNPAIRED_LINE })
        assertEquals(1, asked)
        assertEquals("the next line is whole", "{\"a\":1}", reader.next(skip = { true }) { MAX_UNPAIRED_LINE })
        assertNull("the stream ends in a dropped line", reader.next(skip = { true }) { MAX_UNPAIRED_LINE })
    }

    @Test
    fun timeoutKeepsTheDrop() {
        val data = ("x".repeat(MAX_UNPAIRED_LINE + 100) + "\nnext\n").toByteArray()
        var at = 0
        var timedOut = false
        val input = object : InputStream() {
            override fun read(): Int {
                if (at == MAX_UNPAIRED_LINE + 50 && !timedOut) {
                    timedOut = true
                    throw SocketTimeoutException()
                }
                return if (at < data.size) data[at++].toInt() else -1
            }
        }
        val reader = LineReader(input)
        assertTrue(runCatching { reader.next(skip = { true }) { MAX_UNPAIRED_LINE } }.exceptionOrNull() is SocketTimeoutException)
        assertEquals("the rest of the long line goes too", "", reader.next(skip = { true }) { MAX_UNPAIRED_LINE })
        assertEquals("next", reader.next(skip = { true }) { MAX_UNPAIRED_LINE })
    }

    @Test
    fun limitGrowsDuringLine() {
        // The pairing ends while the line comes, so the paired limit applies.
        var paired = false
        val reader = LineReader(stream("x".repeat(MAX_UNPAIRED_LINE * 2) + "\n"))
        val line = reader.next { if (paired) MAX_LINE else MAX_UNPAIRED_LINE.also { paired = true } }
        assertEquals(MAX_UNPAIRED_LINE * 2, line!!.length)
    }

    @Test
    fun timeoutKeepsPartialLine() {
        val data = "hello world\nnext\n".toByteArray()
        var at = 0
        var timedOut = false
        val input = object : InputStream() {
            override fun read(): Int {
                if (at == 5 && !timedOut) {
                    timedOut = true
                    throw SocketTimeoutException()
                }
                return if (at < data.size) data[at++].toInt() else -1
            }
        }
        val reader = LineReader(input)
        assertTrue(runCatching { reader.next { MAX_LINE } }.exceptionOrNull() is SocketTimeoutException)
        assertEquals("hello world", reader.next { MAX_LINE })
        assertEquals("next", reader.next { MAX_LINE })
        assertNull(reader.next { MAX_LINE })
    }

    @Test
    fun readLineStopsAtEnd() {
        assertEquals("a", readLine(stream("a")))
        assertNull(readLine(stream("")))
    }

    private fun ip(s: String): InetAddress = InetAddress.getByName(s)

    @Test
    fun addressChecks() {
        assertTrue(samePeer(ip("192.168.1.5"), ip("192.168.1.5")))
        assertFalse(samePeer(ip("192.168.1.6"), ip("192.168.1.5")))
        // Other hosts on the LAN share the /64 network of the computer.
        assertTrue(samePeer(ip("2001:db8:1:2::a"), ip("2001:db8:1:2::a")))
        assertFalse(samePeer(ip("2001:db8:1:2::a"), ip("2001:db8:1:2::b")))
        assertFalse(samePeer(ip("192.168.1.5"), ip("2001:db8:1:2::a")))

        assertTrue(isTailscale(ip("100.101.102.103")))
        assertFalse(isTailscale(ip("100.128.0.1")))
        assertTrue(isTailscale(ip("fd7a:115c:a1e0::1234")))
        assertFalse(isTailscale(ip("fd7a:115c:a1e1::1")))

        assertTrue(samePrefix(ip("192.168.1.200"), ip("192.168.1.3"), 24))
        assertFalse(samePrefix(ip("192.168.2.200"), ip("192.168.1.3"), 24))
        assertTrue(samePrefix(ip("10.0.0.130"), ip("10.0.0.129"), 25))
        assertFalse(samePrefix(ip("10.0.0.127"), ip("10.0.0.129"), 25))
    }
}

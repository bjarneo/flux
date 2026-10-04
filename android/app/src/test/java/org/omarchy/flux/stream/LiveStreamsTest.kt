package org.omarchy.flux.stream

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.omarchy.flux.core.StreamKind
import org.omarchy.flux.mic.MicSession
import org.omarchy.flux.webcam.WebcamSession

class LiveStreamsTest {
    private val names = mapOf("a" to "omarchy", "b" to "laptop")
    private fun name(id: String) = names.getValue(id)

    @Test
    fun onlyActiveStreamsWithAComputerCount() {
        assertTrue(liveStreams(WebcamSession.Status(), MicSession.Status()).isEmpty())
        // An error names the computer, but the stream does not run.
        assertTrue(liveStreams(WebcamSession.Status(WebcamSession.Phase.Error, deviceId = "a"), MicSession.Status(MicSession.Phase.Error, "", "a")).isEmpty())
        val streams = liveStreams(
            WebcamSession.Status(WebcamSession.Phase.Connecting, deviceId = "a"),
            MicSession.Status(MicSession.Phase.Live, "", "b"),
        )
        assertEquals(listOf(LiveStream(StreamKind.Webcam, "a", false), LiveStream(StreamKind.Mic, "b", true)), streams)
    }

    @Test
    fun sentenceNamesTheStreamsAndTheComputer() {
        assertEquals("The webcam streams to omarchy", streamSentence(listOf(StreamKind.Webcam), "omarchy", live = true))
        assertEquals("The mic connects to omarchy", streamSentence(listOf(StreamKind.Mic), "omarchy", live = false))
        assertEquals("The webcam and the mic stream to omarchy", streamSentence(listOf(StreamKind.Mic, StreamKind.Webcam), "omarchy", live = true))
        assertEquals("The webcam and the mic connect to omarchy", streamSentence(listOf(StreamKind.Webcam, StreamKind.Mic), "omarchy", live = false))
    }

    @Test
    fun noticeGroupsTheStreamsOfOneComputer() {
        val one = streamNotice(listOf(LiveStream(StreamKind.Mic, "a", true)), ::name)
        assertEquals("The mic streams to omarchy", one.first)
        assertEquals("It keeps running in the background. Tap Stop to end it.", one.second)

        val both = streamNotice(listOf(LiveStream(StreamKind.Webcam, "a", true), LiveStream(StreamKind.Mic, "a", false)), ::name)
        assertEquals("The webcam and the mic connect to omarchy", both.first)
        assertEquals("They keep running in the background. Tap Stop to end one.", both.second)
    }

    @Test
    fun noticeListsTheStreamsOf2Computers() {
        val n = streamNotice(listOf(LiveStream(StreamKind.Webcam, "a", true), LiveStream(StreamKind.Mic, "b", true)), ::name)
        assertEquals("The webcam and the mic stream to 2 computers", n.first)
        assertEquals("The webcam streams to omarchy. The mic streams to laptop.", n.second)
    }

    @Test
    fun noticeOfNoStream() {
        assertEquals("The stream ended", streamNotice(emptyList(), ::name).first)
    }
}

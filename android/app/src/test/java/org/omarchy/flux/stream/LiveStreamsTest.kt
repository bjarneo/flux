package org.omarchy.flux.stream

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.omarchy.flux.core.StreamKind
import org.omarchy.flux.mic.MicSession
import org.omarchy.flux.speaker.SpeakerSession
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
    fun theSpeakerCountsAsAStream() {
        val streams = liveStreams(
            WebcamSession.Status(),
            MicSession.Status(MicSession.Phase.Live, "", "a"),
            SpeakerSession.Status(SpeakerSession.Phase.Live, "", "a", muted = "Laptop Speakers"),
        )
        assertEquals(listOf(LiveStream(StreamKind.Mic, "a", true), LiveStream(StreamKind.Speaker, "a", true)), streams)
        assertTrue(liveStreams(WebcamSession.Status(), MicSession.Status(), SpeakerSession.Status(SpeakerSession.Phase.Error, "", "a")).isEmpty())
        assertEquals(
            listOf(LiveStream(StreamKind.Speaker, "b", false)),
            liveStreams(WebcamSession.Status(), MicSession.Status(), SpeakerSession.Status(SpeakerSession.Phase.Connecting, "", "b")),
        )
    }

    @Test
    fun theSpeakerSentenceTellsWhereTheAudioPlays() {
        assertEquals("The audio of omarchy plays on this phone", streamSentence(listOf(StreamKind.Speaker), "omarchy", live = true))
        assertEquals("The audio of omarchy connects", streamSentence(listOf(StreamKind.Speaker), "omarchy", live = false))
        assertEquals(
            "The mic streams to omarchy. The audio of omarchy plays on this phone",
            streamSentence(listOf(StreamKind.Speaker, StreamKind.Mic), "omarchy", live = true),
        )
        val one = streamNotice(listOf(LiveStream(StreamKind.Speaker, "a", true)), ::name)
        assertEquals("The audio of omarchy plays on this phone", one.first)
        val two = streamNotice(listOf(LiveStream(StreamKind.Mic, "a", true), LiveStream(StreamKind.Speaker, "b", true)), ::name)
        assertEquals("Flux streams with 2 computers", two.first)
        assertEquals("The mic streams to omarchy. The audio of laptop plays on this phone.", two.second)
    }

    @Test
    fun noticeOfNoStream() {
        assertEquals("The stream ended", streamNotice(emptyList(), ::name).first)
    }
}

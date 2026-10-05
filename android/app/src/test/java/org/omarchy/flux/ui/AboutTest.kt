package org.omarchy.flux.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class AboutTest {
    @Test
    fun aReleaseBuildShowsOnlyTheVersion() {
        assertEquals("Version 0.13.0", aboutVersion("0.13.0", debug = false))
    }

    @Test
    fun aDebugBuildSaysSo() {
        assertEquals("Version 0.13.0, debug build", aboutVersion("0.13.0", debug = true))
    }
}

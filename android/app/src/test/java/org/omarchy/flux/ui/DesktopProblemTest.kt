package org.omarchy.flux.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DesktopProblemTest {
    @Test
    fun unknownComputerNamesTheLinkAndTheNextStep() {
        val p = desktopProblem("The computer is not known", "omarchy-desk")
        assertEquals("This phone has no link to omarchy-desk now.", p.cause)
        assertTrue(p.step.startsWith("Check that Flux runs on omarchy-desk"))
    }

    @Test
    fun timeoutAsksForAnUpdate() {
        val p = desktopProblem("omarchy-desk did not connect. Update Flux on the computer.", "omarchy-desk")
        assertEquals("Update Flux on omarchy-desk, then select Start again.", p.step)
    }

    @Test
    fun computerErrorWithACommandKeepsTheCommand() {
        val p = desktopProblem(
            "the remote desktop needs gpu-screen-recorder on the computer. Install it with: sudo pacman -S gpu-screen-recorder",
            "omarchy-desk",
        )
        assertTrue(p.cause.startsWith("The remote desktop needs"))
        assertTrue(p.cause.endsWith("sudo pacman -S gpu-screen-recorder"))
    }

    @Test
    fun otherComputerErrorShowsAsItsReport() {
        val p = desktopProblem("no monitor of Hyprland shows an image to capture", "omarchy-desk")
        assertEquals("omarchy-desk reports: No monitor of Hyprland shows an image to capture.", p.cause)
    }

    @Test
    fun emptyMessageStillGivesAStep() {
        assertEquals("Check the log of fluxd on omarchy-desk, then select Start again.", desktopProblem("", "omarchy-desk").step)
    }
}

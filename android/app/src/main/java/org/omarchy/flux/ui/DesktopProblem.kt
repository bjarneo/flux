package org.omarchy.flux.ui

/** Why the remote desktop does not show, and the next step. */
data class DesktopProblem(val title: String, val cause: String, val step: String)

/**
 * Turns the error of a remote desktop stream into its cause and the next
 * step. [message] comes from the phone or from the computer, and [name] is
 * the name of the computer. A message that this function does not know
 * shows as the report of the computer.
 */
fun desktopProblem(message: String, name: String): DesktopProblem {
    val m = message.trim().trimEnd('.')
    fun problem(cause: String, step: String) = DesktopProblem("The screen does not show", cause, step)
    return when {
        m.isEmpty() || m.endsWith("could not stream its screen") ->
            problem("$name could not start the stream.", "Check the log of fluxd on $name, then select Start again.")
        m.endsWith("is not known") ->
            problem("This phone has no link to $name now.", "Check that Flux runs on $name. When $name connects, select Start again.")
        m.endsWith("is not paired") || m.endsWith("is no longer paired") ->
            problem("$name is not paired with this phone.", "Pair $name again in Computers.")
        m.endsWith("is not connected") || m.startsWith("Not connected to") || m == "The network is not ready" ->
            problem(
                "This phone has no link to $name.",
                "Check that this phone and $name are on the same network or on Tailscale, then select Start again.",
            )
        m.contains("did not connect") ->
            problem("$name did not open the stream in time.", "Update Flux on $name, then select Start again.")
        m.startsWith("The connection did not come from") ->
            problem("A device that is not $name tried to open the stream.", "Select Start again. If this occurs again, pair $name again.")
        m.startsWith("Update Flux on") ->
            problem("This version of Flux on $name does not stream its screen.", "Update Flux on $name, then select Start again.")
        m.startsWith("This phone cannot show the stream") ->
            problem("This phone cannot decode the video of $name.", "Close the other apps that play video, then select Start again.")
        m.endsWith("stopped the stream") || m.startsWith("The connection to") ->
            problem("$name stopped the stream, or the network closed the link.", "Select Start again.")
        else -> {
            // The computer writes its errors in lower case. An error with a command ends with the command.
            val text = m.replaceFirstChar { it.uppercase() }
            if (text.contains("Install it with", ignoreCase = true)) {
                problem(text, "Then select Start again.")
            } else {
                problem("$name reports: $text.", "Correct this on $name, then select Start again.")
            }
        }
    }
}

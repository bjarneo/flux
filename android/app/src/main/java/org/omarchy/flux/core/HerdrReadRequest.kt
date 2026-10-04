package org.omarchy.flux.core

/** Identifies the output mode and file that a screen requests. */
internal data class HerdrReadRequest(val id: Long, val view: String, val path: String) {
    fun accepts(output: HerdrOutput, supportsReview: Boolean): Boolean {
        if (output.request == null) return !supportsReview && view == "ansi" && output.view == "ansi" && output.path.isEmpty()
        return output.request == id && output.view == view && output.path == path
    }
}

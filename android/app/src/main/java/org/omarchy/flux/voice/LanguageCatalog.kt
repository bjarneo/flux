package org.omarchy.flux.voice

/** A language in the language picker of dictation. */
data class LanguageRow(val tag: String, val name: String, val native: String, val state: State) {
    enum class State { Installed, Downloading, Available }
}

/**
 * The language list of the picker. The functions use no Android classes,
 * so the JVM tests cover them.
 */
object LanguageCatalog {
    /**
     * The rows of the picker: the languages on the phone, then the
     * languages that download, then the languages that the recognizer can
     * download. The phone languages go first in their settings order. The
     * other languages go in the order of their names. [query] keeps the
     * languages whose name, own name, or tag contains it.
     */
    fun rows(
        installed: List<String>,
        downloading: Collection<String>,
        supported: List<String>,
        phone: List<String>,
        query: String,
    ): List<LanguageRow> {
        val have = installed.distinct()
        val loading = downloading.filter { it !in have }.distinct()
        val rest = supported.filter { it !in have && it !in loading }.distinct()
        val order = phone.withIndex().associate { it.value to it.index }
        val rows = have.sortedWith(compareBy<String> { order[it] ?: Int.MAX_VALUE }.thenBy { DictationText.languageName(it) })
            .map { row(it, LanguageRow.State.Installed) } +
            loading.sortedBy { DictationText.languageName(it) }.map { row(it, LanguageRow.State.Downloading) } +
            rest.sortedBy { DictationText.languageName(it) }.map { row(it, LanguageRow.State.Available) }
        val q = query.trim()
        if (q.isEmpty()) return rows
        return rows.filter { it.name.contains(q, true) || it.native.contains(q, true) || it.tag.contains(q, true) }
    }

    /** The language that automatic mode uses: the first phone language that is on the phone. */
    fun automatic(phone: List<String>, installed: List<String>): String? = phone.firstOrNull { it in installed }

    /** The name of a language in that language, such as `Deutsch (Deutschland)` for `de-DE`. */
    fun nativeName(tag: String): String {
        val locale = DictationText.displayLocale(tag)
        return DictationText.tidy(locale.getDisplayName(locale)).replaceFirstChar { it.titlecase(locale) }.ifEmpty { tag }
    }

    private fun row(tag: String, state: LanguageRow.State) =
        LanguageRow(tag, DictationText.languageName(tag), nativeName(tag), state)
}

package pl.wojas.macdroidsync

import java.text.Normalizer

/**
 * Finding notes by what they say. Case and Polish marks do not count, so
 * "zolw" finds "żółw"; every word of the query has to be there, in any order.
 * Folding keeps one character for one, so that where a word is found in the
 * folded text is where it is in the text itself.
 */
object NoteSearch {

    fun fold(text: String): String {
        val out = CharArray(text.length)
        for (i in text.indices) out[i] = foldChar(text[i])
        return String(out)
    }

    private fun foldChar(c: Char): Char {
        when (c) {
            'ł', 'Ł' -> return 'l'
            'ß' -> return 's'
        }
        val lower = c.lowercaseChar()
        if (lower.code < 0x80) return lower
        // The letter without its marks: the first part of its decomposition.
        return Normalizer.normalize(lower.toString(), Normalizer.Form.NFD).firstOrNull() ?: lower
    }

    /** The words of a query, folded; empty when there is nothing to look for. */
    fun words(query: String): List<String> = fold(query).split(Regex("\\s+")).filter { it.isNotEmpty() }

    fun matches(text: String, words: List<String>): Boolean {
        if (words.isEmpty()) return true
        val folded = fold(text)
        return words.all { folded.contains(it) }
    }

    /** Where each word is found in [text], as start and end offsets. */
    fun hits(text: String, words: List<String>): List<IntRange> {
        val folded = fold(text)
        val hits = mutableListOf<IntRange>()
        for (word in words) {
            var at = folded.indexOf(word)
            while (at >= 0) {
                hits += at until at + word.length
                at = folded.indexOf(word, at + word.length)
            }
        }
        return hits
    }

    /**
     * A piece of [text] around the first word found, cut at whole words and
     * marked with an ellipsis where it was cut, or null when none is found.
     */
    fun snippet(text: String, words: List<String>, before: Int = 40, length: Int = 200): String? {
        val first = hits(text, words).minByOrNull { it.first } ?: return null
        var start = (first.first - before).coerceAtLeast(0)
        if (start > 0) {
            val space = text.indexOf(' ', start)
            if (space in start until first.first) start = space + 1
        }
        val end = (start + length).coerceAtMost(text.length)
        val piece = text.substring(start, end).trim()
        return (if (start > 0) "…" else "") + piece + (if (end < text.length) "…" else "")
    }
}

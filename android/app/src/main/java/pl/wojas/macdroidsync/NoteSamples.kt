package pl.wojas.macdroidsync

import android.content.Context

/**
 * Sample folders and notes to try the list with, from res/raw/notes_samples.md.
 * Each note there starts with a line such as `@@ folder=Dom age=6h pinned`:
 * its folder, how long ago it was last edited (in m, h or d) and whether it is
 * pinned. A picture is written `![alt](raw:name)` and copied in from the
 * JPEG of that name in [PICTURES]. They are added once, even to a list that
 * has notes already.
 */
object NoteSamples {

    private const val PREFS = "notes"
    private const val ADDED = "samplesAdded"

    private val PICTURES = mapOf(
        "sample_sea" to R.raw.sample_sea,
        "sample_city" to R.raw.sample_city,
        "sample_food" to R.raw.sample_food,
    )

    fun addOnce(context: Context, store: NotesStore) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (prefs.getBoolean(ADDED, false)) return
        val source = context.resources.openRawResource(R.raw.notes_samples).bufferedReader().use { it.readText() }
        val now = System.currentTimeMillis()
        for (chunk in source.split(Regex("(?m)^@@ ")).filter { it.isNotBlank() }) {
            val header = chunk.substringBefore('\n')
            val markdown = chunk.substringAfter('\n').trimEnd()
            val fields = header.split(' ').filter { it.isNotBlank() }
            val folder = fields.firstOrNull { it.startsWith("folder=") }?.substringAfter('=') ?: continue
            val age = fields.firstOrNull { it.startsWith("age=") }?.substringAfter('=').orEmpty()
            val note = store.create(folder, withPictures(context, store, markdown), at = now - millis(age))
            if ("pinned" in fields) store.setPinned(note.id, true)
        }
        prefs.edit().putBoolean(ADDED, true).apply()
    }

    private fun withPictures(context: Context, store: NotesStore, markdown: String) =
        markdown.lines().joinToString("\n") { line ->
            val image = Markdown.parseImage(line)
            val name = image?.path?.removePrefix("raw:")?.takeIf { image.path.startsWith("raw:") } ?: return@joinToString line
            val id = PICTURES[name] ?: return@joinToString line
            val path = store.addImage("jpg") { file ->
                context.resources.openRawResource(id).use { input -> file.outputStream().use { input.copyTo(it) } }
            }
            "![${image.alt}]($path)"
        }

    private fun millis(age: String): Long {
        val amount = age.dropLast(1).toLongOrNull() ?: return 0
        return amount * when (age.lastOrNull()) {
            'm' -> 60_000L
            'h' -> 3_600_000L
            'd' -> 86_400_000L
            else -> 0L
        }
    }
}

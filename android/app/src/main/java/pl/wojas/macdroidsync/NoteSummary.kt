package pl.wojas.macdroidsync

/** What a tile of the notes list shows of a note: its title, the start of its text and its first picture. */
data class NoteSummary(val title: String, val preview: String, val image: String?) {

    companion object {
        /** How much of the text a tile could ever show; the rest is not kept in the index. */
        const val PREVIEW_LIMIT = 280

        /** The whole text of a note as it reads, one line per paragraph, without Markdown; what searching looks through. */
        fun text(markdown: String): String {
            val summary = of(markdown, limit = Int.MAX_VALUE)
            return if (summary.preview.isEmpty()) summary.title else summary.title + "\n" + summary.preview
        }

        fun of(markdown: String): NoteSummary = of(markdown, PREVIEW_LIMIT)

        private fun of(markdown: String, limit: Int): NoteSummary {
            val lines = Markdown.parse(markdown)
            val first = lines.firstOrNull()
            val titled = first != null && first.block.type !in setOf(BlockType.TABLE, BlockType.IMAGE, BlockType.FILE)
            val title = if (titled) first!!.text.trim() else ""
            val image = lines.firstNotNullOfOrNull { it.image?.path }
            val preview = StringBuilder()
            var number = 0
            for (line in if (titled) lines.drop(1) else lines) {
                number = if (line.block.type == BlockType.NUMBERED) number + 1 else 0
                val text = when (line.block.type) {
                    BlockType.IMAGE -> null
                    BlockType.FILE -> line.file?.let { (if (it.isAudio) "🎙 " else "📎 ") + it.name }
                    // A tile has room for the first row; searching looks through them all.
                    BlockType.TABLE -> line.table?.rows?.let { if (limit == Int.MAX_VALUE) it else it.take(1) }
                        ?.joinToString("\n") { row -> row.filter { it.isNotBlank() }.joinToString(" · ") }
                    BlockType.BULLET -> "• " + line.text
                    BlockType.NUMBERED -> "$number. " + line.text
                    BlockType.CHECKBOX -> (if (line.block.checked) "☑ " else "☐ ") + line.text
                    else -> line.text
                }?.trim()
                if (text.isNullOrEmpty() || text == "•") continue
                if (preview.isNotEmpty()) preview.append('\n')
                preview.append(text)
                if (preview.length >= limit) break
            }
            return NoteSummary(title, preview.take(limit).toString(), image)
        }
    }
}

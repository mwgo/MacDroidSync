import Foundation

/// What a row of the notes list shows of a note: its title, the start of its
/// text and its first picture, as on the phone (NoteSummary.kt).
public struct NoteSummary: Equatable, Hashable, Sendable {
    public var title: String
    public var preview: String
    public var image: String?

    public init(title: String, preview: String, image: String?) {
        self.title = title
        self.preview = preview
        self.image = image
    }

    /// How much of the text a row could ever show.
    public static let previewLimit = 280

    /// The whole text of a note as it reads, one line per paragraph, without Markdown; what searching looks through.
    public static func text(_ markdown: String) -> String {
        let summary = of(markdown, limit: .max)
        return summary.preview.isEmpty ? summary.title : summary.title + "\n" + summary.preview
    }

    public static func of(_ markdown: String) -> NoteSummary { of(markdown, limit: previewLimit) }

    private static func of(_ markdown: String, limit: Int) -> NoteSummary {
        let lines = Markdown.parse(markdown)
        let first = lines.first
        let titled = first.map { ![.table, .image, .file].contains($0.block.type) } ?? false
        let title = titled ? first!.text.trimmingCharacters(in: .whitespaces) : ""
        let image = lines.lazy.compactMap { $0.image?.path }.first
        var preview = ""
        var numbers = ListNumbers()
        for line in titled ? Array(lines.dropFirst()) : lines {
            let number = numbers.next(line.block)
            var text: String?
            switch line.block.type {
            case .image: text = nil
            case .file: text = line.file.map { ($0.isAudio ? "🎙 " : "📎 ") + $0.name }
            case .table:
                let rows = line.table?.rows ?? []
                text = (limit == .max ? rows : Array(rows.prefix(1)))
                    .map { $0.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: " · ") }
                    .joined(separator: "\n")
            case .bullet: text = "• " + line.text
            case .numbered: text = "\(number). " + line.text
            case .checkbox: text = (line.block.checked ? "☑ " : "☐ ") + line.text
            default: text = line.text
            }
            guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty, trimmed != "•" else { continue }
            if !preview.isEmpty { preview += "\n" }
            preview += trimmed
            if preview.count >= limit { break }
        }
        return NoteSummary(title: title, preview: limit == .max ? preview : String(preview.prefix(limit)), image: image)
    }
}

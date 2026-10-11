import Foundation
import NotesMDKit

/// Headings that fold their section away, as on the phone: everything below
/// a heading up to the next heading of its level or higher. The text stays
/// in the note and in its Markdown; only the layout leaves it out.
public enum Folding {

    /// A heading that can fold: any but the title, the first line.
    static func canFold(_ text: NSAttributedString, paragraph: NSRange, index: Int) -> Bool {
        index > 0 && AttributedCodec.block(of: text, paragraph: paragraph).type == .heading
    }

    static func isFolded(_ text: NSAttributedString, paragraph: NSRange) -> Bool {
        paragraph.length > 0 && paragraph.location < text.length
            && (text.attribute(.mdFolded, at: paragraph.location, effectiveRange: nil) as? Bool) == true
    }

    static func hasFolds(_ text: NSAttributedString) -> Bool {
        var found = false
        text.enumerateAttribute(.mdFolded, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            if (value as? Bool) == true {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    /// The section of each folded heading, by the heading's paragraph: from
    /// the line after it up to the next heading of its level or higher.
    static func sections(_ text: NSAttributedString) -> [(heading: NSRange, section: NSRange)] {
        guard hasFolds(text) else { return [] }
        let paragraphs = AttributedCodec.paragraphs(text)
        let levels = paragraphs.map { p -> Int in
            let block = AttributedCodec.block(of: text, paragraph: p)
            return block.type == .heading ? max(block.level, 1) : 0
        }
        var result: [(NSRange, NSRange)] = []
        for (index, paragraph) in paragraphs.enumerated() where levels[index] > 0 && index > 0 && isFolded(text, paragraph: paragraph) {
            let end = Markdown.sectionEnd(levels, index)
            let start = NSMaxRange(paragraph)
            let stop = end < paragraphs.count ? paragraphs[end].location : text.length
            result.append((paragraph, NSRange(location: start, length: max(stop - start, 0))))
        }
        return result
    }

    /// What the layout leaves out: the folded sections, the ones inside others merged into them.
    static func hidden(_ text: NSAttributedString) -> [NSRange] {
        var merged: [NSRange] = []
        for range in sections(text).map(\.section) where range.length > 0 {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}

extension NoteEditing {

    /// The headings that can fold, all but the title.
    public var foldableHeadings: [NSRange] {
        paragraphs.enumerated().filter { Folding.canFold(storage, paragraph: $0.element, index: $0.offset) }.map(\.element)
    }

    public func isFolded(_ paragraph: NSRange) -> Bool { Folding.isFolded(storage, paragraph: paragraph) }

    public func toggleFold(paragraph: NSRange) {
        setFolded(!isFolded(paragraph), paragraphs: [paragraph])
    }

    /// The headings that folding everything folds; a single top heading stays
    /// open, as folding it would leave nothing but that heading.
    private var foldTargets: [NSRange] {
        let headings = foldableHeadings
        let levels = headings.map { block(of: $0).level }
        guard let top = levels.min() else { return [] }
        let roots = headings.indices.filter { levels[$0] == top }
        return roots.count == 1 ? headings.enumerated().filter { $0.offset != roots[0] }.map(\.element) : headings
    }

    public var allFolded: Bool {
        let targets = foldTargets
        return !targets.isEmpty && targets.allSatisfy(isFolded)
    }

    public var canFoldAll: Bool { !foldTargets.isEmpty }

    /// Folds every heading while any is open, inner ones too, so that opening
    /// one later shows its subheadings folded; otherwise unfolds them all.
    public func toggleAllFolds() {
        if allFolded {
            setFolded(false, paragraphs: foldableHeadings)
        } else {
            setFolded(true, paragraphs: foldTargets)
        }
    }

    private func setFolded(_ folded: Bool, paragraphs: [NSRange]) {
        let targets = paragraphs.filter { $0.length > 0 && $0.location < storage.length }
        guard !targets.isEmpty else { return }
        storage.beginEditing()
        for paragraph in targets {
            let first = NSRange(location: paragraph.location, length: 1)
            if folded { storage.addAttribute(.mdFolded, value: true, range: first) } else { storage.removeAttribute(.mdFolded, range: first) }
        }
        storage.endEditing()
        layout?.layOutFolds()
    }

    /// Before a change to the text: a folded section opens when the change
    /// reaches into it, or breaks or joins the line of its heading.
    public func unfold(forChange range: NSRange, replacement: String) {
        let sections = Folding.sections(storage)
        guard !sections.isEmpty else { return }
        let string = storage.string as NSString
        let deleted = range.length > 0 && NSMaxRange(range) <= string.length ? string.substring(with: range) : ""
        let lines = replacement.contains("\n") || deleted.contains("\n")
        var open: [NSRange] = []
        for (heading, section) in sections {
            let intoSection = section.length > 0
                && (NSIntersectionRange(range, section).length > 0
                    || (range.location >= section.location && range.location < NSMaxRange(section)))
            let atHeading = lines && range.location >= heading.location && range.location <= NSMaxRange(heading)
            if intoSection || atHeading { open.append(heading) }
        }
        setFolded(false, paragraphs: open)
    }

    /// Where a caret at `location` may stand: never inside a folded section,
    /// but after it going on, or at the end of its heading coming back.
    public func visibleCaret(_ location: Int, forward: Bool) -> Int {
        guard let hidden = layout?.hidden, !hidden.isEmpty else { return location }
        for range in hidden where location >= range.location && location < NSMaxRange(range) {
            return forward ? NSMaxRange(range) : max(range.location - 1, 0)
        }
        return location
    }
}

extension NoteEditing {
    /// The heading whose arrow is at `point`, in the text container's coordinates.
    func foldArrow(at point: CGPoint) -> NSRange? {
        guard let layout else { return nil }
        for heading in foldableHeadings where !layout.isHidden(heading.location) {
            guard let arrow = layout.foldArrowRect(ofParagraph: heading) else { continue }
            // A finger's worth around the arrow: the whole margin left of the heading, 44 points high.
            let target = CGRect(x: arrow.minX - 24, y: arrow.midY - 22, width: arrow.width + 30, height: 44)
            if target.contains(point) { return heading }
        }
        return nil
    }
}

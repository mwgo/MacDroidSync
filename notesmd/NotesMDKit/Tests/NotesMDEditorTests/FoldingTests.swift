import XCTest
import NotesMDKit
@testable import NotesMDEditor

final class FoldingTests: XCTestCase {
    private let source = ["# Title", "## A", "a1", "### A.1", "a2", "## B", "b1"].joined(separator: "\n")

    private func editing() -> (NoteEditing, NoteLayoutManager) {
        let style = EditorStyle(bodySize: 14)
        let storage = NSTextStorage()
        let layout = NoteLayoutManager(style: style)
        storage.addLayoutManager(layout)
        layout.addTextContainer(NSTextContainer(size: CGSize(width: 400, height: CGFloat.greatestFiniteMagnitude)))
        let editing = NoteEditing(storage: storage, style: style, maker: AttachmentMaker(style: style, resolve: { _ in nil }))
        editing.layout = layout
        editing.load(source)
        return (editing, layout)
    }

    private func heading(_ editing: NoteEditing, _ text: String) -> NSRange {
        editing.paragraphs.first { (editing.storage.string as NSString).substring(with: editing.body(of: $0)) == text }!
    }

    private func height(_ layout: NoteLayoutManager) -> CGFloat {
        layout.ensureLayout(for: layout.textContainers[0])
        return layout.usedRect(for: layout.textContainers[0]).height
    }

    func testFoldingHidesTheSectionUpToTheNextHeadingOfItsLevel() {
        let (editing, layout) = editing()
        let full = height(layout)
        editing.toggleFold(paragraph: heading(editing, "A"))
        let string = editing.storage.string as NSString
        XCTAssertEqual(layout.hidden.count, 1)
        XCTAssertEqual(string.substring(with: layout.hidden[0]), "a1\nA.1\na2\n")
        XCTAssertLessThan(height(layout), full)
        XCTAssertEqual(Markdown.parse(editing.markdown()), Markdown.parse(source))
        editing.toggleFold(paragraph: heading(editing, "A"))
        XCTAssertTrue(layout.hidden.isEmpty)
        XCTAssertEqual(height(layout), full, accuracy: 0.5)
    }

    func testFoldAllKeepsASingleTopHeadingOpen() {
        let (editing, layout) = editing()
        XCTAssertTrue(editing.canFoldAll)
        editing.toggleAllFolds()
        XCTAssertTrue(editing.allFolded)
        XCTAssertEqual(layout.hidden.count, 2)
        editing.toggleAllFolds()
        XCTAssertFalse(editing.allFolded)
        XCTAssertTrue(layout.hidden.isEmpty)
    }

    func testTheCaretStepsOverAFoldedSection() {
        let (editing, layout) = editing()
        let a = heading(editing, "A")
        editing.toggleFold(paragraph: a)
        let section = layout.hidden[0]
        XCTAssertEqual(editing.visibleCaret(section.location, forward: true), NSMaxRange(section))
        XCTAssertEqual(editing.visibleCaret(section.location + 2, forward: false), NSMaxRange(a) - 1)
    }

    func testANewLineAtAFoldedHeadingUnfoldsIt() {
        let (editing, layout) = editing()
        let a = heading(editing, "A")
        editing.toggleFold(paragraph: a)
        editing.unfold(forChange: NSRange(location: NSMaxRange(a) - 1, length: 0), replacement: "x")
        XCTAssertFalse(layout.hidden.isEmpty)
        editing.unfold(forChange: NSRange(location: NSMaxRange(a) - 1, length: 0), replacement: "\n")
        XCTAssertTrue(layout.hidden.isEmpty)
    }
}

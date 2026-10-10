import XCTest
import NotesMDKit
@testable import NotesMDEditor

final class NoteEditingTests: XCTestCase {
    private func editing(_ markdown: String) -> NoteEditing {
        let style = EditorStyle(bodySize: 14)
        let editing = NoteEditing(storage: NSTextStorage(), style: style, maker: AttachmentMaker(style: style, resolve: { _ in nil }))
        editing.load(markdown)
        return editing
    }

    /// Types as a text view would: asks first, then changes, then reports.
    private func type(_ text: String, at range: NSRange, into editing: NoteEditing) -> NSRange {
        if let handled = editing.intercept(range: range, replacement: text) { return handled }
        let attributes = editing.typingAttributes(at: range.location)
        editing.storage.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: attributes))
        let selection = NSRange(location: range.location + (text as NSString).length, length: 0)
        return editing.didChange(edited: NSRange(location: range.location, length: (text as NSString).length), replacement: text, selection: selection) ?? selection
    }

    private func type(_ text: String, into editing: NoteEditing, at start: Int) -> NSRange {
        var selection = NSRange(location: start, length: 0)
        for character in text { selection = type(String(character), at: selection, into: editing) }
        return selection
    }

    func testTheSampleSurvivesTheEditor() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("android/app/src/main/res/raw/notes_sample.md")
        let sample = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(Markdown.parse(editing(sample).markdown()), Markdown.parse(sample))
    }

    func testCanonicalMarkdownComesBackAsItWas() {
        let source = [
            "# Tytuł", "- a", "    - [x] b", "1. c", "2. d", "> cytat **mocny**", "```", "kod *nie*", "```",
            "*i* __u__ `k` **b *bi* b**", "| A | B |", "| --- | --- |", "| 1 | 2 |", "![drawing](N.assets/x.png)",
            "[R.pdf](N.assets/u/R.pdf)", "",
        ].joined(separator: "\n")
        XCTAssertEqual(editing(source).markdown(), source)
    }

    func testEnterGoesOnWithAListAndAnEmptyItemEndsIt() {
        let e = editing("# T\n- [x] mleko")
        var caret = e.storage.length
        caret = type("\n", at: NSRange(location: caret, length: 0), into: e).location
        XCTAssertEqual(e.markdown(), "# T\n- [x] mleko\n- [ ] ")
        caret = type("chleb", into: e, at: caret).location
        caret = type("\n", at: NSRange(location: caret, length: 0), into: e).location
        _ = type("\n", at: NSRange(location: caret, length: 0), into: e)
        XCTAssertEqual(e.markdown(), "# T\n- [x] mleko\n- [ ] chleb\n")
    }

    func testMarkdownTypedAtTheStartOfALineBecomesTheBlock() {
        let e = editing("# T\n")
        var caret = type("- ", into: e, at: e.storage.length)
        caret = type("a", into: e, at: caret.location)
        XCTAssertEqual(e.markdown(), "# T\n- a")
        caret = type("\n", at: caret, into: e)
        caret = type("\n", at: caret, into: e)
        caret = type("[] zadanie", into: e, at: caret.location)
        XCTAssertEqual(e.markdown(), "# T\n- a\n- [ ] zadanie")
    }

    func testStarsAroundWordsBecomeBold() {
        let e = editing("# T\n")
        _ = type("to **mocne** tak", into: e, at: e.storage.length)
        XCTAssertEqual(e.markdown(), "# T\nto **mocne** tak")
        XCTAssertEqual(e.storage.string, "T\nto mocne tak")
    }

    func testBackspaceAtTheStartOfAnItemTakesTheListAway() {
        let e = editing("# T\n- x\n    - a")
        let start = (e.storage.string as NSString).range(of: "a").location
        _ = type("", at: NSRange(location: start - 1, length: 1), into: e)
        XCTAssertEqual(e.markdown(), "# T\n- x\n- a")
        _ = type("", at: NSRange(location: start - 1, length: 1), into: e)
        XCTAssertEqual(e.markdown(), "# T\n- x\na")
    }

    func testCommands() {
        let e = editing("# T\nraz\ndwa")
        let all = NSRange(location: 2, length: e.storage.length - 2)
        e.toggleBlock(.checkbox, selection: all)
        XCTAssertEqual(e.markdown(), "# T\n- [ ] raz\n- [ ] dwa")
        e.indent(selection: NSRange(location: e.storage.length - 1, length: 0))
        XCTAssertEqual(e.markdown(), "# T\n- [ ] raz\n    - [ ] dwa")
        e.toggleCheckbox(paragraph: e.paragraph(at: 3))
        XCTAssertEqual(e.markdown(), "# T\n- [x] raz\n    - [ ] dwa")
        XCTAssertEqual(e.tasks().open, 1)
        e.toggle(.bold, selection: NSRange(location: 2, length: 3))
        XCTAssertEqual(e.markdown(), "# T\n- [x] **raz**\n    - [ ] dwa")
        e.insertObject("| a | b |\n| --- | --- |\n| c | d |", at: NSRange(location: 4, length: 0))
        XCTAssertEqual(e.markdown(), "# T\n- [x] **ra**\n| a | b |\n| --- | --- |\n| c | d |\n- [x] **z**\n    - [ ] dwa")
    }
}

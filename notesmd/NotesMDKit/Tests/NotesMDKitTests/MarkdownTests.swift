import XCTest
@testable import NotesMDKit

/// The same rules as the phone's MarkdownTest.kt.
final class MarkdownTests: XCTestCase {

    private func prefix(_ line: String) -> [String]? {
        Markdown.detectBlockPrefix(line).map { ["\($0.0.type)", "\($0.0.level)", "\($0.0.checked)", "\($0.1)"] }
    }

    func testLinePrefixesSwitchTheParagraphMode() {
        XCTAssertEqual(prefix("- "), ["bullet", "0", "false", "2"])
        XCTAssertEqual(prefix("* item"), ["bullet", "0", "false", "2"])
        XCTAssertEqual(prefix("12. "), ["numbered", "0", "false", "4"])
        XCTAssertEqual(prefix("[] "), ["checkbox", "0", "false", "3"])
        XCTAssertEqual(prefix("[ ] "), ["checkbox", "0", "false", "4"])
        XCTAssertEqual(prefix("[x] "), ["checkbox", "0", "true", "4"])
        XCTAssertEqual(prefix("- [ ] "), ["checkbox", "0", "false", "6"])
        XCTAssertEqual(prefix("### "), ["heading", "3", "false", "4"])
        XCTAssertEqual(prefix("> cytat"), ["quote", "0", "false", "2"])
        XCTAssertEqual(prefix(">"), ["quote", "0", "false", "1"])
        XCTAssertNil(prefix(">x"))
        XCTAssertNil(prefix("####### "))
        XCTAssertNil(prefix("-x"))
        XCTAssertNil(prefix("#nope"))
        XCTAssertNil(prefix("a - "))
    }

    func testClosingDelimitersAreFoundAsTheyAreTyped() {
        XCTAssertEqual(Markdown.findClosedInline("to *it*", cursor: 7), InlineMatch(kind: .italic, openStart: 3, closeStart: 6, delimiter: 1))
        XCTAssertEqual(Markdown.findClosedInline("_i_", cursor: 3), InlineMatch(kind: .italic, openStart: 0, closeStart: 2, delimiter: 1))
        XCTAssertEqual(Markdown.findClosedInline("**bold**", cursor: 8), InlineMatch(kind: .bold, openStart: 0, closeStart: 6, delimiter: 2))
        XCTAssertEqual(Markdown.findClosedInline(" __u__", cursor: 6), InlineMatch(kind: .underline, openStart: 1, closeStart: 4, delimiter: 2))
        XCTAssertEqual(Markdown.findClosedInline("`kod`", cursor: 5), InlineMatch(kind: .code, openStart: 0, closeStart: 4, delimiter: 1))
    }

    func testAHalfClosedBoldWaitsForItsSecondStar() {
        XCTAssertNil(Markdown.findClosedInline("**bold*", cursor: 7))
        XCTAssertNil(Markdown.findClosedInline("__u_", cursor: 4))
    }

    func testDelimitersAroundSpacesOrInsideWordsLeaveTheTextAlone() {
        XCTAssertNil(Markdown.findClosedInline("a * nie *", cursor: 9))
        XCTAssertNil(Markdown.findClosedInline("a *nie *", cursor: 8))
        XCTAssertNil(Markdown.findClosedInline("snake_case_", cursor: 11))
        XCTAssertNil(Markdown.findClosedInline("``", cursor: 2))
        XCTAssertEqual(Markdown.parseInline("a * b *").0, "a * b *")
        XCTAssertEqual(Markdown.parseInline("a * b *").1, [])
    }

    func testCodeKeepsItsStars() {
        XCTAssertEqual(Markdown.parseInline("`a*b*c`").0, "a*b*c")
        XCTAssertEqual(Markdown.parseInline("`a*b*c`").1, [InlineStyle(.code, 0, 5)])
        XCTAssertNil(Markdown.findClosedInline("`a*b*", cursor: 5))
    }

    func testInlineStylesNest() {
        let (text, styles) = Markdown.parseInline("**a _b_ c**")
        XCTAssertEqual(text, "a b c")
        XCTAssertEqual(Set(styles), [InlineStyle(.italic, 2, 3), InlineStyle(.bold, 0, 5)])
    }

    func testOffsetsCountUTF16() {
        let (text, styles) = Markdown.parseInline("😀 **żółw**")
        XCTAssertEqual(text, "😀 żółw")
        XCTAssertEqual(styles, [InlineStyle(.bold, 3, 7)])
    }

    func testTableRowsAndSeparators() {
        XCTAssertEqual(Markdown.parseTableRow("| A |  | C |"), ["A", "", "C"])
        XCTAssertNil(Markdown.parseTableRow("a | b"))
        XCTAssertTrue(Markdown.isTableSeparator("|---|:--:|"))
        XCTAssertFalse(Markdown.isTableSeparator("| a |"))
    }

    func testATableIsOneLineOfTheModel() {
        let lines = Markdown.parse("| A | B |\n|---|---|\n| 1 | 2 |\n| 3 |\nafter")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].table, MdTable(rows: [["A", "B"], ["1", "2"], ["3", ""]]))
        XCTAssertEqual(lines[1].text, "after")
    }

    func testATableHasNoHeaderOfItsOwn() {
        let table = MdTable(rows: [["a", "b"], ["c"]])
        XCTAssertEqual(Markdown.toMarkdown([MdLine(Block(.table), table: table)]), "| a | b |\n| --- | --- |\n| c |  |")
    }

    func testAPictureIsALineOfItsOwn() {
        let lines = Markdown.parse("a\n![kot](images/k1.jpg)\n tekst ![x](y.jpg) dalej")
        XCTAssertEqual(lines[1].image, MdImage(path: "images/k1.jpg", alt: "kot"))
        XCTAssertEqual(lines[1].block.type, .image)
        XCTAssertEqual(lines[2].block.type, .paragraph)
        XCTAssertEqual(Markdown.toMarkdown(Array(lines.prefix(2))), "a\n![kot](images/k1.jpg)")
    }

    func testSectionsEndAtTheNextHeadingOfTheSameOrAHigherLevel() {
        let levels = [1, 0, 2, 0, 3, 0, 2, 0, 1]
        XCTAssertEqual(Markdown.sectionEnd(levels, 0), 8)
        XCTAssertEqual(Markdown.sectionEnd(levels, 2), 6)
        XCTAssertEqual(Markdown.sectionEnd(levels, 4), 6)
        XCTAssertEqual(Markdown.sectionEnd(levels, 8), 9)
    }

    func testCanonicalMarkdownIsWrittenBackUnchanged() {
        let source = [
            "# T", "- a", "1. b", "2. c", "- [x] d", "- [ ] e", "> q *r*",
            "**f** *g* __h__ `i` **j *k* l**", "| A | B |", "| --- | --- |", "| 1 | 2 |", "",
        ].joined(separator: "\n")
        XCTAssertEqual(Markdown.toMarkdown(Markdown.parse(source)), source)
    }

    func testAFencedBlockKeepsItsLinesAsTheyAre() {
        let lines = Markdown.parse("a\n```kotlin\nval x = *y*\n\n- z\n```\nb")
        XCTAssertEqual(lines.map(\.text), ["a", "val x = *y*", "", "- z", "b"])
        XCTAssertEqual(lines.map(\.block.type), [.paragraph, .code, .code, .code, .paragraph])
        XCTAssertTrue(lines[1].styles.isEmpty)
        XCTAssertEqual(Markdown.toMarkdown(lines), "a\n```\nval x = *y*\n\n- z\n```\nb")
    }

    func testAnUnclosedFenceRunsToTheEndAndAnEmptyOneStillMakesALine() {
        XCTAssertEqual(Markdown.parse("```\nx\ny").map(\.text), ["x", "y"])
        XCTAssertEqual(Markdown.parse("```\n```"), [MdLine(Block(.code))])
    }

    func testTheSampleSurvivesARoundTrip() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("android/app/src/main/res/raw/notes_sample.md")
        let sample = try String(contentsOf: url, encoding: .utf8)
        let parsed = Markdown.parse(sample)
        XCTAssertEqual(Markdown.parse(Markdown.toMarkdown(parsed)), parsed)
        XCTAssertTrue(parsed.contains { $0.block.type == .table })
    }

    func testALinkIntoTheFilesIsAFileTileAnyOtherLinkIsText() {
        let lines = Markdown.parse("# Pliki\n[Raport roczny.pdf](files/ab/Raport_roczny.pdf)\n[strona](https://example.com)\n[b](Pliki.assets/u/b.pdf)")
        XCTAssertEqual(lines[1].block.type, .file)
        XCTAssertEqual(lines[1].file, MdFile(path: "files/ab/Raport_roczny.pdf", name: "Raport roczny.pdf"))
        XCTAssertEqual(lines[2].block.type, .paragraph)
        XCTAssertEqual(lines[3].block.type, .file)
        XCTAssertEqual(Markdown.parse(Markdown.toMarkdown(lines)), lines)
    }

    func testNestedListItemsKeepTheirDepthAndNumbersCountPerLevel() {
        let source = ["# T", "1. a", "    1. b", "    2. c", "        - [ ] d", "2. e", "    - f"].joined(separator: "\n")
        let lines = Markdown.parse(source)
        XCTAssertEqual(lines.map(\.block.depth), [0, 0, 1, 1, 2, 0, 1])
        XCTAssertEqual(lines[4].block.type, .checkbox)
        XCTAssertEqual(Markdown.toMarkdown(lines), source)
    }

    func testAnyIndentDeeperThanTheItemAboveNestsOneLevel() {
        let lines = Markdown.parse("- a\n  - b\n\t\t- c\n  - d\n- e\n\n   - f")
        XCTAssertEqual(lines.map(\.block.depth), [0, 1, 2, 1, 0, 0, 0])
        XCTAssertEqual(lines.last?.text, "f")
    }

    func testAnIndentedParagraphIsNotAListItem() {
        let lines = Markdown.parse("    tekst")
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].block.type, .paragraph)
        XCTAssertEqual(lines[0].text, "    tekst")
    }

    func testSummaryAndSearch() {
        let summary = NoteSummary.of("# Żółw\n- a\n1. b\n- [x] c\n![](x.jpg)\n[r.m4a](files/u/r.m4a)")
        XCTAssertEqual(summary.title, "Żółw")
        XCTAssertEqual(summary.preview, "• a\n1. b\n☑ c\n🎙 r.m4a")
        XCTAssertEqual(summary.image, "x.jpg")
        let words = NoteSearch.words("zolw")
        XCTAssertTrue(NoteSearch.matches("Mały żółw", words))
        XCTAssertEqual(NoteSearch.hits("Mały żółw", words), [5..<9])
        XCTAssertEqual(NoteSearch.snippet("Mały żółw", words), "Mały żółw")
    }
}

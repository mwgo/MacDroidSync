import XCTest
@testable import MacDroidSyncCore

/// The two directions of the conversion, against HTML as Notes really wrote it.
final class NotesMarkupTests: XCTestCase {

    private func markdown(_ html: String, title: String) -> String {
        NotesMarkup.markdown(fromHTML: html, title: title).markdown
    }

    // MARK: - Markdown to Notes

    func testTheTitleHeadingsListsAndInlineStylesBecomeNotesHTML() {
        let md = """
        # Plan sprintu
        Cel: **eksport** do *PDF*, __pilne__ i `kod`.
        ## Zadania
        - [x] Przegląd
        - [ ] Eksport
        - punkt
        1. jeden
        > cytat
        """
        let html = NotesMarkup.html(fromMarkdown: md).html
        XCTAssertTrue(html.hasPrefix("<div><h1>Plan sprintu</h1></div>"))
        XCTAssertTrue(html.contains("<div>Cel: <b>eksport</b> do <i>PDF</i>, <u>pilne</u> i <tt>kod</tt>.</div>"))
        XCTAssertTrue(html.contains("<div><h2>Zadania</h2></div>"))
        XCTAssertTrue(html.contains("<div>☑ Przegląd</div><div>☐ Eksport</div>"))
        XCTAssertTrue(html.contains("<ul><li>punkt</li></ul><ol><li>jeden</li></ol>"))
        XCTAssertTrue(html.contains("<div>│ cytat</div>"))
    }

    func testTablesCodePicturesAndFiles() {
        let md = """
        # Rzeczy
        | A | B |
        | --- | --- |
        | 1 | 2 |
        ```
        let x = 1 < 2
        ```
        ![](images/00000000-0000-0000-0000-000000000001.jpg)
        [Umowa.pdf](files/00000000-0000-0000-0000-000000000002/Umowa.pdf)
        """
        let out = NotesMarkup.html(fromMarkdown: md)
        XCTAssertTrue(out.html.contains("<table><tbody><tr><td><div>A</div></td><td><div>B</div></td></tr><tr><td><div>1</div></td>"))
        XCTAssertTrue(out.html.contains("<div><tt>let x = 1 &lt; 2</tt></div>"))
        XCTAssertFalse(out.html.contains("<img"))
        let placed = NotesMarkup.html(fromMarkdown: md) { URL(fileURLWithPath: "/w/" + ($0 as NSString).lastPathComponent) }.html
        XCTAssertTrue(placed.contains("</table></div><div><tt>let x = 1 &lt; 2</tt></div><div><img src=\"file:///w/00000000-0000-0000-0000-000000000001.jpg\"></div><div><img src=\"file:///w/Umowa.pdf\"></div>"))
        XCTAssertEqual(out.files.map(\.name), ["00000000-0000-0000-0000-000000000001.jpg", "Umowa.pdf"])
    }

    // MARK: - Notes to Markdown

    /// What Notes made of the HTML above: headings as sized bold text, code as
    /// Courier, the table inside an object, a picture it does not draw.
    func testWhatNotesWritesBackReadsAsTheSameNote() {
        let html = """
        <div><b><font face=".AppleSystemUIFontBold"><span style="font-size: 24px">Tytuł testowy</span></font></b></div>
        <div><b><font face=".AppleSystemUIFontBold"><span style="font-size: 18px">Nagłówek 2</span></font></b></div>
        <div><b><font face=".AppleSystemUIFontBold">Nagłówek 3</font></b></div>
        <div>Tekst <b>pogrubiony</b>, <i>kursywa</i>, <u>podkreślenie</u>, <font face="Courier"><span style="font-size: 12px">kod</span></font>.</div>
        <ul>
        <li>punkt a</li>
        <li>punkt b</li>
        </ul>
        <div>☐ zadanie otwarte</div>
        <div>☑ zadanie zrobione</div>
        <div>│ cytat</div>
        <div><object><table cellspacing="0" cellpadding="0" style="border-collapse: collapse; direction: ltr">
        <tbody>
        <tr><td valign="top" style="border-style: solid"><div>A1</div>
        </td><td valign="top"><div>B1</div>
        </td></tr>
        <tr><td valign="top"><div>A2</div>
        </td><td valign="top"><div>B2</div>
        </td></tr>
        </tbody>
        </table></object><br></div>
        <div><br><br></div>
        <div>po obrazie</div>

        """
        XCTAssertEqual(markdown(html, title: "Tytuł testowy"), """
        # Tytuł testowy
        ## Nagłówek 2
        ### Nagłówek 3
        Tekst **pogrubiony**, *kursywa*, __podkreślenie__, `kod`.
        - punkt a
        - punkt b
        - [ ] zadanie otwarte
        - [x] zadanie zrobione
        > cytat
        | A1 | B1 |
        | --- | --- |
        | A2 | B2 |
        @attachment
        po obrazie
        """)
    }

    /// A note written in Notes itself: real heading tags, an empty line after
    /// the title, nested lists, a link and an entity without its semicolon.
    func testANoteWrittenInNotes() {
        let html = """
        <div><h1>Asystent</h1></div>
        <div><br></div>
        <div><b><h2>Po co to robimy</h2></b></div>
        <div>Nie w stronę &quotfajnej technologii&quot. A &amp; B</div>
        <ul class="Apple-dash-list">
        <li>Ogólne</li>
        <ul>
        <li>Przegląd</li>
        </ul>
        </ul>
        <div>Strona <a href="https://enova.pl">enova.pl</a><br></div>
        <div><tt>monostyled</tt></div>
        <div><tt>druga linia</tt></div>

        """
        XCTAssertEqual(markdown(html, title: "Asystent"), """
        # Asystent

        ## Po co to robimy
        Nie w stronę "fajnej technologii". A & B
        - Ogólne
            - Przegląd
        Strona enova.pl
        ```
        monostyled
        druga linia
        ```
        """)
    }

    func testPicturesInTheBodyComeOutInPlace() {
        let html = "<div><h1>Pitagoras</h1></div>\n<div><img style=\"max-width: 100%;\" src=\"data:image/png;base64,AQID\"/><h1></h1></div>\n<div>tekst</div>"
        let note = NotesMarkup.markdown(fromHTML: html, title: "Pitagoras")
        XCTAssertEqual(note.markdown, "# Pitagoras\n![](@image:0)\ntekst")
        XCTAssertEqual(note.images.first?.data, Data([1, 2, 3]))
        XCTAssertEqual(note.images.first?.mime, "image/png")
    }

    func testANoteWhoseFirstLineIsNotItsNameGetsTheNameAsTitle() {
        XCTAssertEqual(markdown("<div>tekst</div>", title: "Nazwa"), "# Nazwa\ntekst")
        XCTAssertEqual(markdown("<div># Plan</div><div>a</div>", title: "# Plan"), "# # Plan\na")
    }

    func testTheSameNoteIsRecognisedWhateverEitherSideDidToItsForm() {
        let phone = "# Lista zakupów\n- [ ] Mleko\n- [x] **Jajka**\n![](images/x.jpg)"
        let mac = markdown("<div><h1>Lista zakupów</h1></div><div>☐ Mleko</div><div>☑ Jajka</div><div><br><br></div>", title: "Lista zakupów")
        XCTAssertEqual(NotesMarkup.contentKey(phone), NotesMarkup.contentKey(mac))
        XCTAssertNotEqual(NotesMarkup.contentKey(phone), NotesMarkup.contentKey("# Lista zakupów\n- Mleko"))
    }

    func testNestedListsGoInsideTheirParentListAndComeBackAsDeep() {
        let md = "# Lista\n- a\n    - b\n        1. c\n    - [ ] d\n- e\n- [x] f"
        let html = NotesMarkup.html(fromMarkdown: md).html
        XCTAssertTrue(html.contains("<ul><li>a</li><ul><li>b</li><ol><li>c</li></ol><li>☐ d</li></ul><li>e</li></ul><div>☑ f</div>"))
        XCTAssertEqual(markdown(html, title: "Lista"), md)
    }

    func testHeadingsAreToldBySizeAgainstTheTextOfASmallerNote() {
        let html = """
        <div><b><font face=".AppleSystemUIFontBold"><span style="font-size: 21px">Mała</span></font></b></div>
        <div><span style="font-size: 11px">tekst</span></div>
        <div><b><font face=".AppleSystemUIFontBold"><span style="font-size: 15px">Sekcja</span></font></b></div>
        <div><span style="font-size: 11px">dalej</span></div>
        """
        XCTAssertEqual(markdown(html, title: "Mała"), "# Mała\ntekst\n## Sekcja\ndalej")
    }

    func testARoundTripKeepsWhatNotesCanHold() {
        let md = "# Notatka\nTekst **b** i *i*\n- [ ] zadanie\n> cytat\n- punkt\n## Sekcja\n| a | b |\n| --- | --- |\n| c | d |"
        let html = NotesMarkup.html(fromMarkdown: md).html
        XCTAssertEqual(markdown(html, title: "Notatka"), md)
    }
}

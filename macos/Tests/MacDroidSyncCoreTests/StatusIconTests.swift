import AppKit
import XCTest
@testable import MacDroidSyncCore

/// The question this file answers: does the menu bar icon still behave like a
/// menu bar icon once a badge is drawn on it - tinted by the system, the same
/// size whatever the state, and actually different when something is waiting?
final class StatusIconTests: XCTestCase {

    func testTheBadgedIconIsStillATemplateSoTheSystemKeepsTintingIt() {
        let plain = StatusIcon.image(for: .connected)
        let badged = StatusIcon.image(for: .connected, needsAttention: true)
        XCTAssertEqual(plain?.isTemplate, true)
        XCTAssertEqual(badged?.isTemplate, true,
                       "a non-template icon would be black on a dark menu bar")
    }

    /// The error icon is the one state drawn in its own colour, and it has to
    /// stay that way with a dot on it.
    func testTheErrorIconKeepsItsColour() {
        XCTAssertEqual(StatusIcon.image(for: .error)?.isTemplate, false)
        XCTAssertEqual(StatusIcon.image(for: .error, needsAttention: true)?.isTemplate, false)
    }

    /// And the glyph is still in there: a dot on its own is not an icon.
    func testTheGlyphSurvivesTheBadge() throws {
        func opaquePixels(_ image: NSImage) throws -> Int {
            let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            var count = 0
            for x in 0..<rep.pixelsWide {
                for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                    count += 1
                }
            }
            return count
        }
        let plain = try opaquePixels(try XCTUnwrap(StatusIcon.image(for: .connected)))
        let badged = try opaquePixels(
            try XCTUnwrap(StatusIcon.image(for: .connected, needsAttention: true))
        )
        XCTAssertGreaterThan(plain, 0)
        // Scaled by whatever the badged canvas renders at, so compare the share
        // of the glyph rather than raw counts: it must not have been wiped out.
        XCTAssertGreaterThan(badged, plain / 2)
    }

    func testTheBadgeChangesWhatIsDrawn() throws {
        let plain = try XCTUnwrap(StatusIcon.image(for: .connected)?.tiffRepresentation)
        let badged = try XCTUnwrap(
            StatusIcon.image(for: .connected, needsAttention: true)?.tiffRepresentation
        )
        XCTAssertNotEqual(plain, badged)
    }

    /// The glyph must not resize when the dot comes and goes: the canvas grows
    /// instead, so the icon does not jump about while a sync runs.
    func testTheBadgeGrowsTheCanvasRatherThanShrinkingTheGlyph() throws {
        let plain = try XCTUnwrap(StatusIcon.image(for: .connected)).size
        let badged = try XCTUnwrap(StatusIcon.image(for: .connected, needsAttention: true)).size
        XCTAssertGreaterThan(badged.width, plain.width)
        XCTAssertGreaterThan(badged.height, plain.height)
        // And not by so much that the menu bar has to scale it down.
        XCTAssertLessThan(badged.height, 22)
    }

    /// A dot nobody can see is not a request, so it outranks the dimming that
    /// says the phone is away.
    func testSomethingWaitingIsShownAtFullStrengthEvenWhenDisconnected() {
        XCTAssertLessThan(StatusIcon.alpha(for: .disconnected), 1.0)
        XCTAssertEqual(StatusIcon.alpha(for: .disconnected, needsAttention: true), 1.0)
        XCTAssertEqual(StatusIcon.alpha(for: .suspended, needsAttention: true), 1.0)
    }

    func testEveryStateStillHasAnIcon() {
        for state in [PeerState.disconnected, .connecting, .connected, .suspended,
                      .transferring, .error] {
            XCTAssertNotNil(StatusIcon.image(for: state), "\(state) has no icon")
            XCTAssertNotNil(StatusIcon.image(for: state, needsAttention: true),
                            "\(state) has no badged icon")
        }
    }
}

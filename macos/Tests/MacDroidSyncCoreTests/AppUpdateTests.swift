import CryptoKit
import XCTest
@testable import MacDroidSyncCore

final class AppUpdateTests: XCTestCase {

    // MARK: - Versions

    func testVersionsCompareByNumberNotByText() {
        XCTAssertLessThan(AppVersion("0.2")!, AppVersion("0.10")!)
        XCTAssertLessThan(AppVersion("0.9.9")!, AppVersion("1.0")!)
        XCTAssertEqual(AppVersion("v0.2")!, AppVersion("0.2.0")!)
        XCTAssertFalse(AppVersion("0.2")! < AppVersion("0.2")!)
    }

    func testTheTagsLeadingVIsDropped() {
        XCTAssertEqual(AppVersion("v0.3")?.description, "0.3")
    }

    func testSomethingThatIsNotAVersionIsRejected() {
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("0.3-beta"))
        XCTAssertNil(AppVersion("latest"))
        XCTAssertNil(AppVersion("0..3"))
    }

    // MARK: - The feed

    private func release(
        tag: String, draft: Bool = false, prerelease: Bool = false, assets: [String]
    ) -> Data {
        let list = assets.map {
            #"{"name":"\#($0)","browser_download_url":"https://github.com/x/releases/download/\#(tag)/\#($0)"}"#
        }
        return Data(
            #"{"tag_name":"\#(tag)","draft":\#(draft),"prerelease":\#(prerelease),"html_url":"https://github.com/x/releases/tag/\#(tag)","assets":[\#(list.joined(separator: ","))]}"#
                .utf8
        )
    }

    func testANewerReleaseIsFoundWithItsArchiveAndSignature() throws {
        let json = release(tag: "v0.3", assets: [
            "MacDroidSync-0.3.apk", "MacDroidSync-0.3-macos.zip", "MacDroidSync-0.3-macos.zip.sig",
        ])
        let update = try XCTUnwrap(UpdateFeed.update(from: json, newerThan: AppVersion("0.2")!))
        XCTAssertEqual(update.version, AppVersion("0.3")!)
        XCTAssertEqual(update.archiveURL.lastPathComponent, "MacDroidSync-0.3-macos.zip")
        XCTAssertEqual(update.signatureURL?.lastPathComponent, "MacDroidSync-0.3-macos.zip.sig")
    }

    func testTheSameOrAnOlderReleaseIsNoUpdate() throws {
        let json = release(tag: "v0.2", assets: ["MacDroidSync-0.2-macos.zip"])
        XCTAssertNil(try UpdateFeed.update(from: json, newerThan: AppVersion("0.2")!))
        XCTAssertNil(try UpdateFeed.update(from: json, newerThan: AppVersion("0.3")!))
    }

    func testDraftsAndPrereleasesAreNeverOffered() throws {
        let draft = release(tag: "v0.3", draft: true, assets: ["MacDroidSync-0.3-macos.zip"])
        let pre = release(tag: "v0.3", prerelease: true, assets: ["MacDroidSync-0.3-macos.zip"])
        XCTAssertNil(try UpdateFeed.update(from: draft, newerThan: AppVersion("0.2")!))
        XCTAssertNil(try UpdateFeed.update(from: pre, newerThan: AppVersion("0.2")!))
    }

    func testAReleaseWithoutAMacArchiveIsAnErrorNotSilence() {
        let json = release(tag: "v0.3", assets: ["MacDroidSync-0.3.apk"])
        XCTAssertThrowsError(try UpdateFeed.update(from: json, newerThan: AppVersion("0.2")!)) {
            XCTAssertEqual($0 as? UpdateFeed.FeedError, .noArchive("MacDroidSync-0.3-macos.zip"))
        }
    }

    func testAnUnsignedReleaseIsFoundButCarriesNoSignature() throws {
        let json = release(tag: "v0.3", assets: ["MacDroidSync-0.3-macos.zip"])
        let update = try XCTUnwrap(UpdateFeed.update(from: json, newerThan: AppVersion("0.2")!))
        XCTAssertNil(update.signatureURL)
    }

    func testGarbageIsMalformed() {
        XCTAssertThrowsError(try UpdateFeed.update(from: Data("{}".utf8), newerThan: AppVersion("0.2")!))
        XCTAssertThrowsError(try UpdateFeed.update(from: Data("<html>".utf8), newerThan: AppVersion("0.2")!))
    }

    // MARK: - The signature

    func testAnArchiveSignedWithTheKeyIsAccepted() throws {
        let key = Curve25519.Signing.PrivateKey()
        let archive = Data("the archive".utf8)
        let signature = Data(try key.signature(for: archive).base64EncodedString().utf8)
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        XCTAssertTrue(UpdateSignature.isValid(archive: archive, signature: signature, publicKey: publicKey))
    }

    func testATamperedArchiveIsRejected() throws {
        let key = Curve25519.Signing.PrivateKey()
        let signature = Data(try key.signature(for: Data("the archive".utf8)).base64EncodedString().utf8)
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        XCTAssertFalse(UpdateSignature.isValid(
            archive: Data("the archivf".utf8), signature: signature, publicKey: publicKey
        ))
    }

    func testAnArchiveSignedWithAnotherKeyIsRejected() throws {
        let archive = Data("the archive".utf8)
        let signature = Data(try Curve25519.Signing.PrivateKey().signature(for: archive).base64EncodedString().utf8)
        let publicKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        XCTAssertFalse(UpdateSignature.isValid(archive: archive, signature: signature, publicKey: publicKey))
    }

    func testASignatureThatIsNotBase64IsRejected() {
        let publicKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        XCTAssertFalse(UpdateSignature.isValid(
            archive: Data("x".utf8), signature: Data("not a signature".utf8), publicKey: publicKey
        ))
    }

    // MARK: - The schedule

    func testAFirstCheckIsDue() {
        XCTAssertTrue(UpdateSchedule.isDue(lastCheck: nil, now: Date()))
    }

    func testACheckIsDueOnceADay() {
        let now = Date()
        XCTAssertFalse(UpdateSchedule.isDue(lastCheck: now.addingTimeInterval(-23 * 3600), now: now))
        XCTAssertTrue(UpdateSchedule.isDue(lastCheck: now.addingTimeInterval(-24 * 3600), now: now))
    }

    func testAClockMovedBackDoesNotPostponeTheNextCheck() {
        let now = Date()
        XCTAssertTrue(UpdateSchedule.isDue(lastCheck: now.addingTimeInterval(3600), now: now))
    }
}

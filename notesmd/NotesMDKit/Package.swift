// swift-tools-version:5.9
import PackageDescription

// What Notes MD on the Mac, iPad and iPhone and the notes sync of MacDroidSync
// share: the Markdown of the notes and the folder of them on iCloud Drive.
let package = Package(
    name: "NotesMDKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "NotesMDKit", targets: ["NotesMDKit"]),
        .library(name: "NotesMDEditor", targets: ["NotesMDEditor"]),
        .library(name: "AppleNotesBridge", targets: ["AppleNotesBridge"]),
    ],
    targets: [
        .target(name: "NotesMDKit"),
        // The editor of a note, the same on the Mac (AppKit) and on iPad and iPhone (UIKit).
        .target(name: "NotesMDEditor", dependencies: ["NotesMDKit"]),
        // Notes on the Mac read and written by script, for import and export; macOS only.
        .target(name: "AppleNotesBridge", dependencies: ["NotesMDKit"]),
        .testTarget(name: "NotesMDKitTests", dependencies: ["NotesMDKit"]),
        .testTarget(name: "AppleNotesBridgeTests", dependencies: ["AppleNotesBridge"]),
        .testTarget(name: "NotesMDEditorTests", dependencies: ["NotesMDEditor"]),
    ]
)

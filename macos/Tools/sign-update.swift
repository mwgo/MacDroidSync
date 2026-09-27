// Signs MacDroidSync release archives for the automatic update.
//
//   swift Tools/sign-update.swift generate <private-key-file>
//       Creates a key pair. The private key goes to <private-key-file> (mode 600),
//       the public key to <private-key-file>.pub and to stdout: paste it into
//       UpdateKey.publicKey in Sources/MacDroidSyncCore/AppUpdate.swift.
//
//   swift Tools/sign-update.swift sign <private-key-file> <archive.zip>
//       Writes <archive.zip>.sig, to be uploaded next to the archive.
//
//   swift Tools/sign-update.swift verify <public-key-base64> <archive.zip>
//       Checks <archive.zip>.sig the way the app will.
//
// Keep the private key outside the repository and back it up: without it no
// installed copy can be updated automatically again.

import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func readPrivateKey(_ path: String) -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8),
          let bytes = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: bytes)
    else { fail("cannot read a private key from \(path)") }
    return key
}

let arguments = CommandLine.arguments.dropFirst()
switch (arguments.first, arguments.count) {
case ("generate", 2):
    let path = arguments[arguments.startIndex + 1]
    guard !FileManager.default.fileExists(atPath: path) else { fail("\(path) already exists, not overwriting it") }
    let key = Curve25519.Signing.PrivateKey()
    let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
    guard FileManager.default.createFile(
        atPath: path,
        contents: Data(key.rawRepresentation.base64EncodedString().utf8),
        attributes: [.posixPermissions: 0o600]
    ) else { fail("cannot write \(path)") }
    try? Data((publicKey + "\n").utf8).write(to: URL(fileURLWithPath: path + ".pub"))
    print(publicKey)

case ("sign", 3):
    let key = readPrivateKey(arguments[arguments.startIndex + 1])
    let archivePath = arguments[arguments.startIndex + 2]
    guard let archive = FileManager.default.contents(atPath: archivePath) else { fail("cannot read \(archivePath)") }
    let signature = try key.signature(for: archive).base64EncodedString()
    try Data((signature + "\n").utf8).write(to: URL(fileURLWithPath: archivePath + ".sig"))
    print("\(archivePath).sig")

case ("verify", 3):
    let publicText = arguments[arguments.startIndex + 1]
    let archivePath = arguments[arguments.startIndex + 2]
    guard let keyBytes = Data(base64Encoded: publicText),
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes)
    else { fail("not a public key: \(publicText)") }
    guard let archive = FileManager.default.contents(atPath: archivePath),
          let signatureText = try? String(contentsOfFile: archivePath + ".sig", encoding: .utf8),
          let signature = Data(base64Encoded: signatureText.trimmingCharacters(in: .whitespacesAndNewlines))
    else { fail("cannot read \(archivePath) or its .sig") }
    guard key.isValidSignature(signature, for: archive) else { fail("the signature does not verify") }
    print("valid")

default:
    fail("usage: sign-update.swift generate <key> | sign <key> <archive> | verify <public-key> <archive>")
}

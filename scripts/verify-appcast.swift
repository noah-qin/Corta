// Holds the update feed, the signatures in it and the archives it points
// at to one invariant (issue raised 2026-09-25).
//
// `scripts/check-release.sh --appcast` establishes that invariant for the
// version being released, at the moment it is released. Two things were
// missing from it, and this tool is both:
//
//   1. It checked that `sparkle:edSignature` was *present*, never that it
//      was *valid*. A signature made with a private key whose public half
//      is not the `SUPublicEDKey` the shipped app carries is a perfectly
//      well-formed signature that every installed Corta rejects — an
//      update nobody can install, with green checks all the way through.
//      The SHA-256 sidecar does not catch it: it proves the bytes are the
//      published bytes, not that the key pairs with the app.
//
//   2. Nothing looked at the feed again afterwards. `appcast.xml` on
//      `main` *is* the live feed (`SUFeedURL` points straight at it), so a
//      hand edit, a bad merge or a corrupted older entry is served to
//      every running Corta and no check ever runs against it.
//
//   verify-appcast.swift [APPCAST] [PLIST]
//       [--archive PATH --version V] [--download]
//
// With no options it is offline and needs nothing built: structure, the
// enclosure URL each item must carry for its own version, build numbers
// unique and ordered, signature and key well-formed. That is the layer
// cheap enough to run on every CI run.
//
// `--archive PATH --version V` additionally verifies that item's signature
// over a local archive — the release-time check, still offline.
//
// `--download` fetches every enclosure and verifies every item. That is
// the whole invariant, and it is what the nightly run does.
//
// Exit status is the number of failed checks, as `check-release.sh` does.

import CryptoKit
import Foundation

// MARK: - Arguments

var appcastPath = "appcast.xml"
var plistPath = "Sparkle-Info.plist"
var archivePath: String?
var archiveVersion: String?
var download = false
var positional: [String] = []

var arguments = Array(CommandLine.arguments.dropFirst())
while let argument = arguments.first {
    arguments.removeFirst()
    switch argument {
    case "--archive": archivePath = arguments.isEmpty ? nil : arguments.removeFirst()
    case "--version": archiveVersion = arguments.isEmpty ? nil : arguments.removeFirst()
    case "--download": download = true
    default: positional.append(argument)
    }
}
if positional.count > 0 { appcastPath = positional[0] }
if positional.count > 1 { plistPath = positional[1] }
if (archivePath == nil) != (archiveVersion == nil) {
    FileHandle.standardError.write(Data("--archive and --version go together\n".utf8))
    exit(2)
}

var failures = 0
func fail(_ message: String) {
    print("FAIL  \(message)")
    failures += 1
}
func pass(_ message: String) { print("ok    \(message)") }

/// Exit status is the number of failed checks, as `check-release.sh` does.
func finish() -> Never {
    if failures == 0 {
        print("verify-appcast: all checks passed")
    } else {
        print("verify-appcast: \(failures) check(s) failed")
    }
    exit(Int32(min(failures, 125)))
}

// MARK: - The public key the shipped app carries

guard let plistData = FileManager.default.contents(atPath: plistPath),
    let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil)
        as? [String: Any]
else {
    fail("cannot read \(plistPath)")
    exit(1)
}
guard let publicKeyBase64 = plist["SUPublicEDKey"] as? String else {
    fail("\(plistPath) has no SUPublicEDKey")
    exit(1)
}
guard let publicKeyBytes = Data(base64Encoded: publicKeyBase64), publicKeyBytes.count == 32,
    let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyBytes)
else {
    fail("SUPublicEDKey is not a 32-byte Ed25519 public key")
    exit(1)
}
pass("SUPublicEDKey is a well-formed Ed25519 public key")

// MARK: - The feed

struct Item {
    let shortVersion: String
    let build: Int
    let url: String
    let length: Int
    let signature: Data
}

guard let document = try? XMLDocument(contentsOf: URL(fileURLWithPath: appcastPath)) else {
    fail("cannot parse \(appcastPath) as XML")
    exit(1)
}
pass("\(appcastPath) is well-formed XML")

let sparkleNamespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"
func sparkleText(_ element: XMLElement, _ name: String) -> String? {
    element.elements(forName: "sparkle:\(name)").first?.stringValue
}

var items: [Item] = []
let itemElements = (try? document.nodes(forXPath: "//item")) as? [XMLElement] ?? []
if itemElements.isEmpty { fail("the feed has no <item>") }

for element in itemElements {
    let short = sparkleText(element, "shortVersionString") ?? "?"
    guard let buildText = sparkleText(element, "version"), let build = Int(buildText) else {
        fail("item \(short) has no integer sparkle:version — Sparkle compares build numbers")
        continue
    }
    guard let enclosure = element.elements(forName: "enclosure").first else {
        fail("item \(short) has no <enclosure>")
        continue
    }
    guard let url = enclosure.attribute(forName: "url")?.stringValue else {
        fail("item \(short) enclosure has no url")
        continue
    }
    guard let lengthText = enclosure.attribute(forName: "length")?.stringValue,
        let length = Int(lengthText), length > 0
    else {
        fail("item \(short) enclosure has no positive length")
        continue
    }
    let signatureAttribute =
        enclosure.attribute(forName: "sparkle:edSignature")
        ?? enclosure.attribute(forLocalName: "edSignature", uri: sparkleNamespace)
    guard let signatureText = signatureAttribute?.stringValue,
        let signature = Data(base64Encoded: signatureText), signature.count == 64
    else {
        fail("item \(short) has no base64 64-byte sparkle:edSignature")
        continue
    }
    let expectedURL =
        "https://github.com/noah-qin/Corta/releases/download/v\(short)/Corta-\(short).zip"
    if url != expectedURL {
        fail("item \(short) enclosure url is \(url), expected \(expectedURL)")
    }
    items.append(
        Item(shortVersion: short, build: build, url: url, length: length, signature: signature))
}

if !items.isEmpty {
    pass("\(items.count) item(s) carry a version, a build, an enclosure and a signature")
}

// Sparkle offers whichever item has the highest build number, so a repeat
// makes one release invisible to everyone on the other.
let builds = items.map(\.build)
if Set(builds).count != builds.count {
    fail("build numbers repeat in the feed: \(builds)")
} else if !items.isEmpty {
    pass("build numbers are unique")
}
if builds != builds.sorted(by: >) {
    fail("items are not newest-first by build number: \(builds)")
} else if !items.isEmpty {
    pass("items are newest-first by build number")
}
let shortVersions = items.map(\.shortVersion)
if Set(shortVersions).count != shortVersions.count {
    fail("versions repeat in the feed: \(shortVersions)")
}

// MARK: - Signatures

func verify(_ item: Item, bytes: Data, source: String) {
    if bytes.count != item.length {
        fail("\(item.shortVersion): \(source) is \(bytes.count) bytes, feed says \(item.length)")
        return
    }
    if publicKey.isValidSignature(item.signature, for: bytes) {
        pass("\(item.shortVersion): signature verifies under SUPublicEDKey (\(bytes.count) bytes)")
    } else {
        fail(
            "\(item.shortVersion): sparkle:edSignature does NOT verify under the app's "
                + "SUPublicEDKey — every installed Corta would reject this update")
    }
}

if let archivePath, let archiveVersion {
    guard let item = items.first(where: { $0.shortVersion == archiveVersion }) else {
        fail("the feed has no item for \(archiveVersion)")
        finish()
    }
    guard let bytes = FileManager.default.contents(atPath: archivePath) else {
        fail("cannot read \(archivePath)")
        finish()
    }
    verify(item, bytes: bytes, source: archivePath)
}

if download {
    for item in items {
        guard let url = URL(string: item.url) else {
            fail("\(item.shortVersion): enclosure url is not a URL")
            continue
        }
        do {
            let bytes = try Data(contentsOf: url)
            verify(item, bytes: bytes, source: item.url)
        } catch {
            fail("\(item.shortVersion): cannot download \(item.url) — \(error.localizedDescription)")
        }
    }
}

finish()

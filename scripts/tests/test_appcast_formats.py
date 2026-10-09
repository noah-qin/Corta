# Copyright 2026 Noah Qin
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# SPDX-License-Identifier: Apache-2.0

"""Verify signed ZIP/DMG feed fixtures without changing the app's update key."""

from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
GENERATOR = r'''
import CryptoKit
import Foundation
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let version = CommandLine.arguments[2], suffix = CommandLine.arguments[3]
let bytes = Data("signed fixture bytes; not a production disk image".utf8)
let key = Curve25519.Signing.PrivateKey()
let name = "Corta-\(version).\(suffix)"
try bytes.write(to: directory.appendingPathComponent(name))
let signature = try key.signature(for: bytes).base64EncodedString()
let xml = """
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
<sparkle:version>11</sparkle:version><sparkle:shortVersionString>\(version)</sparkle:shortVersionString>
<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
<enclosure url="https://github.com/noah-qin/Corta/releases/download/v\(version)/\(name)" length="\(bytes.count)" type="application/octet-stream" sparkle:edSignature="\(signature)"/>
</item></channel></rss>

"""
let content = Data(xml.utf8)
let signed = xml + "<!-- sparkle-signatures:\nedSignature: \(try key.signature(for: content).base64EncodedString())\nlength: \(content.count)\n-->\n"
try Data(signed.utf8).write(to: directory.appendingPathComponent("appcast.xml"))
let plist: [String: Any] = ["SUPublicEDKey": key.publicKey.rawRepresentation.base64EncodedString(),
 "SURequireSignedFeed": true, "SUVerifyUpdateBeforeExtraction": true, "SUSignedFeedFailureExpirationInterval": 0]
try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
 .write(to: directory.appendingPathComponent("key.plist"))
'''


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("swift"), "CryptoKit fixtures require macOS")
class AppcastFormatTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temporary.name)
        source = cls.root / "generate.swift"
        source.write_text(GENERATOR)
        cls.generator = cls.root / "generate"
        subprocess.run(["swiftc", str(source), "-o", str(cls.generator)], check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def verify(self, version, suffix):
        with tempfile.TemporaryDirectory() as directory:
            subprocess.run([str(self.generator), directory, version, suffix], check=True, capture_output=True)
            return subprocess.run(["swift", str(ROOT / "scripts/verify-appcast.swift"),
                                   str(Path(directory) / "appcast.xml"), str(Path(directory) / "key.plist"),
                                   "--archive", str(Path(directory) / f"Corta-{version}.{suffix}"),
                                   "--version", version], capture_output=True, text=True)

    def test_signed_dmg_item_and_archive_pass(self):
        result = self.verify("1.1.9", "dmg")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("signature verifies", result.stdout)

    def test_last_zip_remains_valid(self):
        result = self.verify("1.1.8", "zip")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_formats_cannot_cross_the_transition_boundary(self):
        for version, suffix in (("1.1.9", "zip"), ("1.1.8", "dmg"), ("1.2.0", "zip")):
            result = self.verify(version, suffix)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("enclosure url", result.stdout)

// Copyright 2026 Noah Qin
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import Corta

/// The notices a redistributed Sparkle requires travel inside the app, and
/// describe the Sparkle actually linked.
@MainActor
struct AcknowledgementsTests {
    @Test("the bundle carries Sparkle's license, with every notice it bundles")
    func licenseIsBundled() throws {
        let text = try #require(AcknowledgementsView.sparkleLicense)
        #expect(text.contains("Copyright (c) 2006-2013 Andy Matuschak."))
        #expect(text.contains("Permission is hereby granted, free of charge"))
        // The BSD- and zlib-style notices of the code Sparkle bundles.
        #expect(text.contains("Colin Percival"))
        #expect(text.contains("Yuta Mori"))
        #expect(text.contains("Orson Peters"))
        #expect(text.contains("Mark Hamlin"))
    }

    @Test("the acknowledged version is the one Package.resolved pins")
    func versionMatchesTheResolvedPackage() throws {
        let resolved = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Corta.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: resolved)) as? [String: Any]
        let pins = try #require(object?["pins"] as? [[String: Any]])
        let sparkle = try #require(pins.first { ($0["identity"] as? String) == "sparkle" })
        let version = (sparkle["state"] as? [String: Any])?["version"] as? String
        #expect(
            version == AcknowledgementsView.sparkleVersion,
            "Sparkle moved to \(version ?? "?"): copy its LICENSE into Corta/Acknowledgements/ and update sparkleVersion")
    }
}

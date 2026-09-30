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

/// Mouse events the child subscribed to (`?1000`/`?1002`/`?1003`).
public enum MouseTrackingMode: Int, Sendable {
    case off = 0
    case normal = 1000
    case buttonEvent = 1002
    case anyEvent = 1003
}

/// Terminal state that is not the grid, surfaced read-only through
/// `Terminal` and `TerminalSession`.
public struct PerformerState: Sendable {
    /// Query responses for the child. Fixed-format only — never text the
    /// input stream supplied (`SECURITY.md` §2.1–2.2).
    public internal(set) var outputBuffer: [UInt8] = []
    public internal(set) var bracketedPasteEnabled = false
    /// Independent of the wire encoding; the last mode enabled wins.
    public internal(set) var mouseTrackingMode: MouseTrackingMode = .off
    public internal(set) var sgrMouseEncodingEnabled = false
    public internal(set) var synchronizedOutputEnabled = false
    /// Bumped on every `?2026` rising edge, including one that shares a
    /// batch with the previous episode's end — which a bool cannot show.
    public internal(set) var synchronizedOutputEpisode = 0
    public internal(set) var bellRequested = false
    /// Never reported back: the title query is a command-injection vector.
    public internal(set) var windowTitle: String?
    /// Local only; a report naming another host goes to `remoteContext`.
    public internal(set) var workingDirectory: String?
    /// Informational only — nothing that spawns a process may read it.
    public internal(set) var remoteContext: RemoteContext?
    public internal(set) var focusReportingEnabled = false
    /// DECSCL; gates which sequences may answer (DECRQM above all).
    public internal(set) var conformanceLevel = 65
    /// LNM — implemented, or a program relying on it prints a staircase.
    public internal(set) var newLineModeEnabled = false
    public internal(set) var applicationCursorKeysEnabled = false
    public internal(set) var applicationKeypadEnabled = false
    public internal(set) var keyboardProtocol = KeyboardProtocolStack()
    public internal(set) var dynamicColors = DynamicColors()
    public internal(set) var indexedPalette = IndexedPalette()
    public internal(set) var specialColors = SpecialColors()
    /// Absolute rows and columns from OSC 133, so a status lands on its
    /// prompt however far output has scrolled since.
    public internal(set) var promptRow: Int?
    /// While the cursor still sits here, nothing has been typed — the gate
    /// for an app-initiated `cd` (`ViewController.canChangeDirectorySafely`).
    public internal(set) var promptEndColumn: Int?
    public internal(set) var outputStartRow: Int?
    public internal(set) var isCommandRunning = false
    /// Set by the first `C`. Only a shell that marks where output begins can
    /// be judged by a `C` missing; one that sends only `A` and `D` never will.
    public internal(set) var shellMarksOutputStart = false
    /// An ED 2 wiped the waiting prompt; its repaint's `B` says where it is now.
    var promptAwaitsRepaint = false
    /// This prompt's `B` has arrived: the shell is waiting for a command line.
    var sawPromptEnd = false
    /// Drained by `Terminal.takeFinishedCommand()`, so a notification fires
    /// once per command, not once per frame.
    public internal(set) var finishedCommandExitStatus: Int?
    public internal(set) var commandExitStatus: Int?
    public internal(set) var commandRecords = CommandRecordStore()
    /// OSC 52 writes only. The read form would hand the clipboard to the
    /// child and stays unimplemented (`SECURITY.md` §6).
    public internal(set) var pendingClipboardCopy: String?
    var pendingImageTransmission: PendingImageTransmission?

    public init() {}
}

/// A Kitty graphics transmission across chunks, kept as base64 text: a
/// chunk boundary need not fall on a 4-character boundary.
struct PendingImageTransmission: Sendable {
    var header: KittyGraphics.TransmitHeader
    var display: KittyGraphics.DisplayHeader?
    var base64: [UInt8]
}

/// OSC 10/11/12's colours, 8 bits per channel; reported by doubling each
/// byte into xterm's 16-bit form.
public struct DynamicColors: Sendable, Equatable {
    public var foreground: (red: UInt8, green: UInt8, blue: UInt8)
    public var background: (red: UInt8, green: UInt8, blue: UInt8)
    public var cursor: (red: UInt8, green: UInt8, blue: UInt8)

    public init(
        foreground: (red: UInt8, green: UInt8, blue: UInt8) = (245, 245, 245),
        background: (red: UInt8, green: UInt8, blue: UInt8) = (35, 40, 51),
        cursor: (red: UInt8, green: UInt8, blue: UInt8) = (245, 245, 245)
    ) {
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
    }

    public static func == (lhs: DynamicColors, rhs: DynamicColors) -> Bool {
        lhs.foreground == rhs.foreground && lhs.background == rhs.background
            && lhs.cursor == rhs.cursor
    }
}

/// Query responses (`CONFORMANCE.md` §1.2): an unanswered probe stalls or
/// misdetects. Every answer is fixed bytes or numbers (`SECURITY.md` §2.2).
extension Performer {
    /// DA1, the VT220 form, claiming only what Corta honours (132 columns,
    /// SGR colour) — claiming more invites probes that go unanswered.
    private static let primaryDeviceAttributes = Array("\u{1B}[?62;1;22c".utf8)

    /// DA2: VT220, no version — capability detection stays conservative.
    private static let secondaryDeviceAttributes = Array("\u{1B}[>1;0;0c".utf8)

    mutating func reportPrimaryDeviceAttributes() {
        state.outputBuffer.append(contentsOf: Self.primaryDeviceAttributes)
    }

    mutating func reportSecondaryDeviceAttributes() {
        state.outputBuffer.append(contentsOf: Self.secondaryDeviceAttributes)
    }

    /// DSR 5 (status) and 6 (cursor position, 1-based).
    mutating func reportDeviceStatus(_ parameters: Parameters) {
        switch parameters.value(0, default: 0) {
        case 5:
            // Silence reads as "the terminal is dead".
            state.outputBuffer.append(contentsOf: Array("\u{1B}[0n".utf8))
        case 6:
            state.outputBuffer.append(
                contentsOf: Array("\u{1B}[\(grid.cursor.row + 1);\(grid.cursor.column + 1)R".utf8)
            )
        default:
            break
        }
    }

    /// DECXCPR (`CSI ? 6 n`); the page is always 1.
    mutating func reportExtendedCursorPosition(_ parameters: Parameters) {
        guard parameters.value(0, default: 0) == 6 else { return }
        state.outputBuffer.append(
            contentsOf: Array(
                "\u{1B}[?\(grid.cursor.row + 1);\(grid.cursor.column + 1);1R".utf8)
        )
    }

    /// `CSI 18 t` only — the text-area size esctest asks for. The title
    /// report (21) is a command-injection vector and never implemented.
    mutating func reportWindowManipulation(_ parameters: Parameters) {
        guard parameters.value(0, default: 0) == 18 else { return }
        state.outputBuffer.append(
            contentsOf: Array("\u{1B}[8;\(grid.rows);\(grid.columns)t".utf8)
        )
    }
}

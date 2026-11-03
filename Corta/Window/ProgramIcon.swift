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

import AppKit

/// A small, fixed catalogue. Only process facts choose artwork; terminal
/// output cannot supply a file path, image URL, or executable to load.
enum ProgramIcon: String, CaseIterable {
    case terminal, python, claude, codex, kimi, grok, gemini, qwen, opencode, aider, ollama
    // The language's own name, as its tile shows it.
    // swiftlint:disable:next identifier_name
    case copilot, goose, node, bun, deno, ruby, go, rust, java, php, lua, swift, julia, r, ssh
    case sftp, mosh, git, docker, kubernetes, vim, neovim, emacs, tmux, screen, npm, pnpm, yarn
    case postgres, mysql, redis, sqlite, top

    private struct Style {
        var name: String?
        var artwork: String
        var color: UInt32
        var aliases: [String]
    }

    private static let styles: [Self: Style] = [
        .terminal: Style(name: nil, artwork: "TerminalTabIcon", color: 0x444444, aliases: []),
        .python: Style(name: "Python", artwork: "ProgramPython", color: 0x366EA1,
            aliases: ["python", "python3", "ipython", "ipython3", "pypy", "pypy3"]),
        .claude: Style(name: "Claude", artwork: "ProgramClaude", color: 0xC96E52, aliases: ["claude", "claude-code"]),
        .codex: Style(name: "Codex", artwork: "ProgramCodex", color: 0xFFFFFF,
            aliases: ["codex", "codex-aarch64-apple-darwin", "codex-x86_64-apple-darwin"]),
        .kimi: Style(name: "Kimi", artwork: "ProgramKimi", color: 0x2E45E6, aliases: ["kimi", "kimi-cli", "kimi_cli"]),
        .grok: Style(name: "Grok", artwork: "ProgramGrok", color: 0x242424, aliases: ["grok", "grok-cli"]),
        .gemini: Style(name: "Gemini", artwork: "ProgramGemini", color: 0x526CE8, aliases: ["gemini", "gemini-cli"]),
        .qwen: Style(name: "Qwen", artwork: "ProgramQwen", color: 0x6552D9, aliases: ["qwen", "qwen-code"]),
        .opencode: Style(name: "OpenCode", artwork: "ProgramOpencode", color: 0x414141,
            aliases: ["opencode", "opencode-ai"]),
        .aider: Style(name: "Aider", artwork: "sf:sparkles", color: 0x337247, aliases: ["aider"]),
        .ollama: Style(name: "Ollama", artwork: "ProgramOllama", color: 0x303030, aliases: ["ollama"]),
        .copilot: Style(name: "Copilot", artwork: "ProgramCopilot", color: 0x6154A4,
            aliases: ["copilot", "github-copilot-cli"]),
        .goose: Style(name: "Goose", artwork: "ProgramGoose", color: 0xA9693E, aliases: ["goose"]),
        .node: Style(name: "Node.js", artwork: "ProgramNode", color: 0x488342, aliases: ["node", "nodejs"]),
        .bun: Style(name: "Bun", artwork: "ProgramBun", color: 0x6E5749, aliases: ["bun"]),
        .deno: Style(name: "Deno", artwork: "ProgramDeno", color: 0x333333, aliases: ["deno"]),
        .ruby: Style(name: "Ruby", artwork: "ProgramRuby", color: 0xB73532, aliases: ["ruby", "irb"]),
        .go: Style(name: "Go", artwork: "ProgramGo", color: 0x007D9C, aliases: ["go", "gofmt"]),
        .rust: Style(name: "Rust", artwork: "ProgramRust", color: 0xA85B39, aliases: ["rustc", "cargo", "rustup"]),
        .java: Style(name: "Java", artwork: "ProgramJava", color: 0xAB5239, aliases: ["java", "javac", "jshell"]),
        .php: Style(name: "PHP", artwork: "ProgramPhp", color: 0x686DA0, aliases: ["php"]),
        .lua: Style(name: "Lua", artwork: "ProgramLua", color: 0x30309A, aliases: ["lua", "luajit"]),
        .swift: Style(name: "Swift", artwork: "ProgramSwift", color: 0xD9693B, aliases: ["swift", "swiftc"]),
        .julia: Style(name: "Julia", artwork: "ProgramJulia", color: 0x8057A6, aliases: ["julia"]),
        .r: Style(name: "R", artwork: "ProgramR", color: 0x3768A0, aliases: ["r", "rscript"]),
        .ssh: Style(name: "SSH", artwork: "sf:lock.shield", color: 0x427D87, aliases: ["ssh"]),
        .sftp: Style(name: "SFTP", artwork: "sf:folder", color: 0x3D829C, aliases: ["sftp", "scp", "rsync"]),
        .mosh: Style(name: "Mosh", artwork: "sf:antenna.radiowaves.left.and.right", color: 0x3D8B76,
            aliases: ["mosh", "mosh-client", "mosh-server"]),
        .git: Style(name: "Git", artwork: "ProgramGit", color: 0xC85B42, aliases: ["git", "lazygit", "tig"]),
        .docker: Style(name: "Docker", artwork: "ProgramDocker", color: 0x267DB4,
            aliases: ["docker", "docker-compose", "lazydocker"]),
        .kubernetes: Style(name: "Kubernetes", artwork: "ProgramKubernetes", color: 0x4169B5,
            aliases: ["kubectl", "k9s", "helm"]),
        .vim: Style(name: "Vim", artwork: "ProgramVim", color: 0x347D43, aliases: ["vim", "vi", "view"]),
        .neovim: Style(name: "Neovim", artwork: "ProgramNeovim", color: 0x4F8E45, aliases: ["nvim", "neovim"]),
        .emacs: Style(name: "Emacs", artwork: "ProgramEmacs", color: 0x755BA3, aliases: ["emacs", "emacsclient"]),
        .tmux: Style(name: "tmux", artwork: "ProgramTmux", color: 0x467D57,
            aliases: ["tmux", "tmux: client", "tmux: server"]),
        .screen: Style(name: "Screen", artwork: "sf:rectangle.split.2x2", color: 0x5B7088, aliases: ["screen"]),
        .npm: Style(name: "npm", artwork: "ProgramNpm", color: 0xB74444,
            aliases: ["npm", "npx", "npm-cli.js", "npx-cli.js"]),
        .pnpm: Style(name: "pnpm", artwork: "ProgramPnpm", color: 0xA96C22,
            aliases: ["pnpm", "pnpx", "pnpm.cjs", "pnpm.js"]),
        .yarn: Style(name: "Yarn", artwork: "ProgramYarn", color: 0x3681A2, aliases: ["yarn", "yarnpkg", "yarn.js"]),
        .postgres: Style(name: "PostgreSQL", artwork: "ProgramPostgres", color: 0x3F6989, aliases: ["psql", "pgcli"]),
        .mysql: Style(name: "MySQL", artwork: "ProgramMysql", color: 0x427C96, aliases: ["mysql", "mariadb", "mycli"]),
        .redis: Style(name: "Redis", artwork: "ProgramRedis", color: 0xB94242, aliases: ["redis-cli", "valkey-cli"]),
        .sqlite: Style(name: "SQLite", artwork: "ProgramSqlite", color: 0x417A98, aliases: ["sqlite", "sqlite3"]),
        .top: Style(name: "Processes", artwork: "sf:chart.bar.xaxis", color: 0x668359,
            aliases: ["top", "htop", "btop"]),
    ]
    private var style: Style { Self.styles[self]! }
    private static let aliases: [String: Self] = Dictionary(uniqueKeysWithValues:
        styles.flatMap { icon, style in style.aliases.map { ($0, icon) } })

    static func identify(_ process: String?, entryPoint: String? = nil) -> Self {
        let name = ((process ?? "") as NSString).lastPathComponent.lowercased()
        let base = directIdentity(name)
        if [.node, .bun, .deno, .python].contains(base), let entryPoint {
            let entry = entryPoint.lowercased()
            let components = entry.split(separator: "/").map(String.init)
            let packages: [String: Self] = [
                "claude-code": .claude, "gemini-cli": .gemini, "grok-cli": .grok,
                "qwen-code": .qwen, "opencode-ai": .opencode, "kimi-cli": .kimi,
            ]
            // A package segment must be underneath node_modules, rather than
            // an arbitrary project directory named after an agent.
            if let moduleIndex = components.lastIndex(of: "node_modules") {
                let package = components.dropFirst(moduleIndex + 1).prefix(2)
                if let match = package.compactMap({ packages[$0] }).first { return match }
            }
            let candidate = directIdentity((entry as NSString).lastPathComponent)
            let wrapped: Set<Self> = [.claude, .codex, .kimi, .grok, .gemini, .qwen,
                .opencode, .aider, .ollama, .copilot, .goose, .npm, .pnpm, .yarn, .python]
            if wrapped.contains(candidate) { return candidate }
        }
        return base
    }

    private static func directIdentity(_ name: String) -> Self {
        if let exact = aliases[name] { return exact }
        let versioned: [(String, Self)] = [("python", .python), ("ruby", .ruby),
            ("php", .php), ("lua", .lua), ("node", .node)]
        for (prefix, icon) in versioned where name.hasPrefix(prefix) {
            let version = name.dropFirst(prefix.count)
            if version.first?.isNumber == true,
               version.allSatisfy({ $0.isNumber || $0 == "." }) { return icon }
        }
        return .terminal
    }

    var displayName: String? { style.name }

    var symbol: NSImage? {
        if style.artwork.hasPrefix("sf:") {
            return NSImage(systemSymbolName: String(style.artwork.dropFirst(3)), accessibilityDescription: nil)
        }
        return NSImage(named: style.artwork)
    }

    private var tileColor: NSColor {
        let rgb = style.color
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                       green: CGFloat((rgb >> 8) & 255) / 255,
                       blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }

    private static var tiles: [Self: NSImage] = [:]

    /// A tab tile is a small window, wider than tall, as a terminal is.
    static let tileSize = NSSize(width: 24, height: 18)

    /// A shell: a near-black tile with a prompt, the way a terminal reads
    /// at a glance, light enough in weight that a row of them is calm.
    private static var shellTile: NSImage {
        // Square-cornered: the card around it (`TabIcon.card`) rounds tile and
        // rim from one radius, so their corners stay concentric.
        let image = NSImage(size: Self.tileSize, flipped: false) { rect in
            NSColor(srgbRed: 0.17, green: 0.17, blue: 0.18, alpha: 1).setFill()
            rect.fill()
            // On the device-pixel grid at 2x: a 1.5 pt stroke, a cursor
            // bar whose edges fall on whole pixels. A 1.4 pt line was soft.
            let green = NSColor(srgbRed: 0.55, green: 0.90, blue: 0.62, alpha: 1)
            green.setStroke()
            let chevron = NSBezierPath()
            chevron.lineWidth = 1.5
            chevron.lineCapStyle = .round
            chevron.lineJoinStyle = .round
            chevron.move(to: NSPoint(x: 6, y: 12))
            chevron.line(to: NSPoint(x: 9, y: 9))
            chevron.line(to: NSPoint(x: 6, y: 6))
            chevron.stroke()
            NSColor.white.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: NSRect(x: 11, y: 5.5, width: 6.5, height: 1.5),
                         xRadius: 0.75, yRadius: 0.75).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Coloured tiles in the tab strip, monochrome marks in pane headers.
    /// The result is cached; streaming output does not redraw these bitmaps.
    var tabImage: NSImage? {
        if let cached = Self.tiles[self] { return cached }
        if self == .terminal {
            let image = Self.shellTile
            Self.tiles[self] = image
            return image
        }
        guard let symbol else { return nil }
        let color = tileColor
        // A light tile (Codex's white) carries a dark mark and a grey edge.
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let light = rgb.redComponent * 0.2126 + rgb.greenComponent * 0.7152 + rgb.blueComponent * 0.0722 > 0.6
        let markColor: NSColor = light ? NSColor(white: 0.1, alpha: 1) : .white
        let mark = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            // Fitted, not stretched: SF Symbols are rarely square.
            let size = symbol.size
            let scale = min(rect.width / max(size.width, 1), rect.height / max(size.height, 1))
            let fitted = NSSize(width: size.width * scale, height: size.height * scale)
            symbol.draw(in: NSRect(x: (rect.width - fitted.width) / 2, y: (rect.height - fitted.height) / 2,
                                   width: fitted.width, height: fitted.height))
            markColor.setFill()
            rect.fill(using: .sourceIn)
            return true
        }
        // Square-cornered, as the shell tile: `TabIcon.card` rounds it.
        let image = NSImage(size: Self.tileSize, flipped: false) { rect in
            color.setFill()
            rect.fill()
            mark.draw(in: NSRect(x: (rect.width - 12) / 2, y: (rect.height - 12) / 2, width: 12, height: 12))
            return true
        }
        image.isTemplate = false
        Self.tiles[self] = image
        return image
    }
}

struct ProgramTabLabel: Equatable {
    var icon: ProgramIcon
    var name: String
    var context: String

    var text: String { context.isEmpty ? name : name + "  " + context }
}

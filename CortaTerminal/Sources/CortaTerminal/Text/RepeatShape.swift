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

/// The structure of a repeated group's body, read only as far as
/// `Search.isCatastrophic` needs: which characters each piece can take,
/// whether it must take one, and whether it repeats without bound.
/// Anything it cannot reason about counts as any character, so an unusual
/// pattern is refused rather than let through.
enum RepeatShape {
    /// What one atom can consume. `any` is the conservative answer.
    struct CharacterSet: Equatable {
        var isAny = false
        var characters: Set<Character> = []
        /// `d`, `w` and `s`, for `\d`, `\w` and `\s`.
        var classes: Set<Character> = []

        static let any = CharacterSet(isAny: true)

        mutating func formUnion(_ other: CharacterSet) {
            isAny = isAny || other.isAny
            characters.formUnion(other.characters)
            classes.formUnion(other.classes)
        }

        /// Whether no character could be taken by both. Uncertain is false.
        func isDisjoint(from other: CharacterSet) -> Bool {
            if isAny || other.isAny { return false }
            if !characters.isDisjoint(with: other.characters) { return false }
            for left in classes {
                for right in other.classes where Self.classesOverlap(left, right) { return false }
                if other.characters.contains(where: { Self.isMember($0, of: left) }) { return false }
            }
            for right in other.classes where characters.contains(where: { Self.isMember($0, of: right) }) {
                return false
            }
            return true
        }

        private static func classesOverlap(_ left: Character, _ right: Character) -> Bool {
            left == right || Set([left, right]) == ["d", "w"]
        }

        /// Broader than ICU's own classes, never narrower: a wrong "yes"
        /// only refuses a pattern.
        private static func isMember(_ character: Character, of characterClass: Character) -> Bool {
            switch characterClass {
            case "d": character.isNumber
            case "w": character.isLetter || character.isNumber || character == "_" || !character.isASCII
            case "s": character.isWhitespace
            default: true
            }
        }
    }

    struct Atom {
        /// Everything it can take, across all its repetitions.
        var set: CharacterSet
        /// What its first character can be.
        var first: CharacterSet
        /// Matches nothing itself: an anchor, a lookaround.
        var isZeroWidth = false
        var minimum = 1
        var isUnbounded = false
        /// A group with an unbounded repeat somewhere inside.
        var containsUnbounded = false
        /// A group whose every alternative can match nothing.
        var isNullable = false

        var isRequired: Bool { !isZeroWidth && minimum >= 1 && !isNullable }
        var consumesUnbounded: Bool { isUnbounded || containsUnbounded }
    }

    /// Whether repeating a group with this body without bound can split
    /// one text between iterations more than one way.
    static func isAmbiguous(_ body: [Character]) -> Bool {
        let alternatives = parseAlternatives(body)
        if alternatives.count > 1 {
            var firsts: [CharacterSet] = []
            for alternative in alternatives {
                guard let first = firstSet(of: alternative) else { return true }
                if firsts.contains(where: { !$0.isDisjoint(from: first) }) { return true }
                firsts.append(first)
            }
        }
        for alternative in alternatives {
            for (index, atom) in alternative.enumerated() where atom.consumesUnbounded {
                // What the iteration holds besides this atom, to the next time
                // it comes round: the rest of it, then its start again.
                let cycle = alternative[(index + 1)...] + alternative[..<index]
                let separated = cycle.contains { $0.isRequired && $0.set.isDisjoint(from: atom.set) }
                if !separated { return true }
            }
        }
        return false
    }

    /// The characters an alternative can start with; nil when it can match
    /// nothing, which an unbounded repeat turns into endless ways to match.
    private static func firstSet(of alternative: [Atom]) -> CharacterSet? {
        var first = CharacterSet()
        for atom in alternative where !atom.isZeroWidth {
            first.formUnion(atom.first)
            if atom.isRequired { return first }
        }
        return nil
    }

    // MARK: - Parsing

    private static func parseAlternatives(_ body: [Character]) -> [[Atom]] {
        var alternatives: [[Atom]] = [[]]
        var index = 0
        while index < body.count {
            if body[index] == "|" {
                alternatives.append([])
                index += 1
                continue
            }
            guard var atom = parseAtom(body, at: &index) else { continue }
            applyQuantifier(body, at: &index, to: &atom)
            alternatives[alternatives.count - 1].append(atom)
        }
        return alternatives
    }

    private static func parseAtom(_ body: [Character], at index: inout Int) -> Atom? {
        let character = body[index]
        switch character {
        case "\\":
            let escaped = index + 1 < body.count ? body[index + 1] : "\\"
            index += 2
            switch escaped {
            case "d", "w", "s":
                let set = CharacterSet(classes: [escaped])
                return Atom(set: set, first: set)
            case "b", "B", "A", "z", "Z", "G":
                return Atom(set: CharacterSet(), first: CharacterSet(), isZeroWidth: true)
            case "n": return literal("\n")
            case "t": return literal("\t")
            case "r": return literal("\r")
            default:
                // A letter or digit escape is a class, a property or a
                // backreference this does not read; punctuation is itself.
                if escaped.isLetter || escaped.isNumber {
                    if index < body.count, body[index] == "{" { skipBraces(body, at: &index) }
                    return Atom(set: .any, first: .any)
                }
                return literal(escaped)
            }
        case "[":
            return parseClass(body, at: &index)
        case "(":
            return parseGroup(body, at: &index)
        case ".":
            index += 1
            return Atom(set: .any, first: .any)
        case "^", "$":
            index += 1
            return Atom(set: CharacterSet(), first: CharacterSet(), isZeroWidth: true)
        case ")":
            // Unbalanced; nothing to reason about.
            index += 1
            return Atom(set: .any, first: .any)
        default:
            index += 1
            return literal(character)
        }
    }

    private static func literal(_ character: Character) -> Atom {
        // Folded, so a case-insensitive search is judged too.
        let set = CharacterSet(characters: Set(character.lowercased()).union(character.uppercased()))
        return Atom(set: set, first: set)
    }

    private static func parseClass(_ body: [Character], at index: inout Int) -> Atom {
        index += 1
        var set = CharacterSet()
        if index < body.count, body[index] == "^" {
            set = .any
            index += 1
        }
        var previous: Character?
        var isFirst = true
        while index < body.count, body[index] != "]" || isFirst {
            isFirst = false
            let character = body[index]
            if character == "\\", index + 1 < body.count {
                let escaped = body[index + 1]
                if "dws".contains(escaped) {
                    set.classes.insert(escaped)
                } else if escaped.isLetter || escaped.isNumber {
                    set = .any
                } else {
                    set.characters.insert(escaped)
                }
                previous = nil
                index += 2
                continue
            }
            if character == "-", let low = previous, index + 1 < body.count, body[index + 1] != "]" {
                let high = body[index + 1]
                if let lowValue = low.unicodeScalars.first?.value, let highValue = high.unicodeScalars.first?.value,
                    lowValue <= highValue, highValue - lowValue <= 256
                {
                    for value in lowValue...highValue {
                        if let scalar = Unicode.Scalar(value) { set.characters.insert(Character(scalar)) }
                    }
                } else {
                    set = .any
                }
                previous = nil
                index += 2
                continue
            }
            if character == "[" { set = .any }  // a nested or POSIX class
            set.characters.insert(character)
            previous = character
            index += 1
        }
        index += 1
        var folded = set
        for character in set.characters {
            folded.characters.formUnion(character.lowercased())
            folded.characters.formUnion(character.uppercased())
        }
        return Atom(set: folded, first: folded)
    }

    private static func parseGroup(_ body: [Character], at index: inout Int) -> Atom {
        let open = index
        var depth = 0
        var close = body.count
        var scan = index
        while scan < body.count {
            let character = body[scan]
            if character == "\\" {
                scan += 2
                continue
            }
            if character == "[" {
                scan += 1
                while scan < body.count, body[scan] != "]" { scan += body[scan] == "\\" ? 2 : 1 }
                scan += 1
                continue
            }
            if character == "(" { depth += 1 }
            if character == ")" {
                depth -= 1
                if depth == 0 {
                    close = scan
                    break
                }
            }
            scan += 1
        }
        index = min(body.count, close + 1)
        var inner = Array(body[(open + 1)..<min(close, body.count)])
        if inner.first == "?" {
            let marker = inner.dropFirst().prefix(2)
            if marker.first == "=" || marker.first == "!" || marker == ["<", "="] || marker == ["<", "!"] {
                return Atom(set: CharacterSet(), first: CharacterSet(), isZeroWidth: true)
            }
            if marker.first == ":" {
                inner = Array(inner.dropFirst(2))
            } else if marker.first == "<", let end = inner.firstIndex(of: ">") {
                inner = Array(inner[(end + 1)...])
            } else {
                // Flags and the rest: not read.
                return Atom(set: .any, first: .any)
            }
        }
        let alternatives = parseAlternatives(inner)
        var set = CharacterSet()
        var first = CharacterSet()
        var containsUnbounded = false
        var isNullable = true
        for alternative in alternatives {
            for atom in alternative {
                set.formUnion(atom.set)
                containsUnbounded = containsUnbounded || atom.consumesUnbounded
            }
            if let alternativeFirst = firstSet(of: alternative) {
                first.formUnion(alternativeFirst)
                isNullable = false
            } else {
                for atom in alternative { first.formUnion(atom.first) }
            }
        }
        return Atom(set: set, first: first, containsUnbounded: containsUnbounded, isNullable: isNullable)
    }

    /// `*`, `+`, `?`, `{n}`, `{n,}` and `{n,m}`, with a lazy or possessive
    /// marker after; an unreadable brace is a literal, as ICU reads it.
    private static func applyQuantifier(_ body: [Character], at index: inout Int, to atom: inout Atom) {
        guard index < body.count else { return }
        switch body[index] {
        case "*":
            atom.minimum = 0
            atom.isUnbounded = true
            index += 1
        case "+":
            atom.isUnbounded = true
            index += 1
        case "?":
            atom.minimum = 0
            index += 1
        case "{":
            guard let brace = body[index...].firstIndex(of: "}") else { return }
            let inside = String(body[(index + 1)..<brace])
            let parts = inside.split(separator: ",", omittingEmptySubsequences: false)
            guard let low = parts.first.flatMap({ Int($0) }), parts.count <= 2 else { return }
            atom.minimum = min(atom.minimum, low)
            if parts.count == 2 {
                if parts[1].isEmpty {
                    atom.isUnbounded = true
                } else if Int(parts[1]) == nil {
                    return
                }
            }
            index = brace + 1
        default:
            return
        }
        if index < body.count, body[index] == "?" || body[index] == "+" { index += 1 }
    }

    private static func skipBraces(_ body: [Character], at index: inout Int) {
        while index < body.count, body[index] != "}" { index += 1 }
        index += 1
    }
}

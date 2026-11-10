import Foundation

enum ConfigEdits {
    static let begin = "<!-- BEGIN STANDMIXER ROUTING -->"
    static let end = "<!-- END STANDMIXER ROUTING -->"
    static let ownership = "Managed by StandMixer. Changes inside this file are replaced on Apply."

    static func managedBlock(in source: String, body: String) throws -> String {
        let starts = source.components(separatedBy: begin)
        let ends = source.components(separatedBy: end)
        guard starts.count == ends.count, starts.count <= 2 else {
            throw StandMixerError.invalid("Routing instructions contain duplicate or incomplete StandMixer markers. Repair those markers before applying.")
        }
        let block = "\(begin)\n\(body)\n\(end)"
        if let start = source.range(of: begin), let finish = source.range(of: end), start.lowerBound < finish.lowerBound {
            return String(source[..<start.lowerBound]) + block + String(source[finish.upperBound...])
        }
        guard starts.count == 1 else { throw StandMixerError.invalid("StandMixer routing markers are reversed. Repair them before applying.") }
        return source + (source.isEmpty || source.hasSuffix("\n\n") ? "" : source.hasSuffix("\n") ? "\n" : "\n\n") + block + "\n"
    }

    /// Edits only bare/quoted root scalar keys. Other bytes, including multiline strings and tables, survive.
    /// This is a lexical boundary scanner, not a TOML serializer; ambiguous target values are refused.
    static func codexSettings(_ source: String, model: String, effort: String?) throws -> String {
        guard model != Route.autoControllerModelID else { return source }
        return try codexEditing(source, requested: ["model": model, "model_reasoning_effort": effort])
    }

    static func codexEditing(_ source: String, requested: [String: String?], observing: ((String, String) -> Void)? = nil) throws -> String {
        var scanner = TOMLScanner()
        var inRoot = true
        var found = Set<String>()
        let bytes = Array(source.utf8)
        var edits: [SourceReplacement] = []
        var lineStart = 0
        var firstTable: Int?
        let expression = try NSRegularExpression(pattern: #"^\s*(model|model_reasoning_effort|"model"|"model_reasoning_effort"|'model'|'model_reasoning_effort')\s*="#)
        while lineStart < bytes.count {
            let lineEnd = bytes[lineStart...].firstIndex(of: 10) ?? bytes.count
            let totalEnd = lineEnd < bytes.count ? lineEnd + 1 : lineEnd
            let line = String(decoding: bytes[lineStart..<lineEnd], as: UTF8.self)
            let neutral = scanner.isNeutral
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if neutral && (inRoot || trimmed.hasPrefix("[")) {
                // A quoted key can legally spell model with Unicode escapes. Refuse ambiguous key
                // spellings rather than prepend a duplicate root key to otherwise valid TOML.
                let keyPrefix = trimmed.prefix { $0 != "=" }
                if (trimmed.hasPrefix("\"") || trimmed.hasPrefix("[")) && keyPrefix.contains("\\") {
                    throw StandMixerError.invalid("Codex config uses escaped key names. Use plain key names before applying so StandMixer can preserve its structure safely.")
                }
                let conflicting = #"^\s*(?:\[{1,2}\s*)?(?:model|model_reasoning_effort|"model"|"model_reasoning_effort"|'model'|'model_reasoning_effort')\s*[.\]]"#
                if trimmed.range(of: conflicting, options: .regularExpression) != nil {
                    throw StandMixerError.invalid("Codex model settings use a table or dotted key instead of a scalar. Repair them before applying.")
                }
            }
            if neutral && trimmed.hasPrefix("[") {
                if inRoot { firstTable = lineStart }
                inRoot = false
            }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            let match = inRoot && neutral ? expression.firstMatch(in: line, range: range) : nil
            if let match, let keyRange = Range(match.range(at: 1), in: line) {
                let key = String(line[keyRange]).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                guard found.insert(key).inserted else { throw StandMixerError.invalid("Codex config has duplicate root \(key) keys; fix it before applying.") }
                var targetScan = TOMLScanner()
                try targetScan.scan(line)
                guard targetScan.isNeutral else { throw StandMixerError.invalid("Codex \(key) uses a multiline value. Replace it with a scalar before applying.") }
                guard let valueStart = Range(NSRange(location: NSMaxRange(match.range), length: 0), in: line)?.lowerBound else {
                    throw StandMixerError.invalid("Codex \(key) could not be located safely.")
                }
                let scalar = try TOMLScalar(line: line, after: line[..<valueStart].utf8.count, key: key)
                observing?(key, scalar.value)
                guard requested.keys.contains(key) else {
                    try scanner.scan(line)
                    lineStart = totalEnd
                    continue
                }
                let desired = requested[key] ?? nil
                if let requested = desired {
                    if scalar.value != requested {
                        let replacement = scalar.isLiteral && !requested.contains("'") ? "'\(requested)'" : tomlString(requested)
                        edits.append(.init(range: (lineStart + scalar.range.lowerBound)..<(lineStart + scalar.range.upperBound), text: replacement))
                    }
                } else {
                    let indentation = String(line.prefix { $0 == " " || $0 == "\t" })
                    let comment = scalar.comment.map { indentation + String(decoding: Array(line.utf8)[$0...], as: UTF8.self) + (lineEnd < bytes.count ? "\n" : "") } ?? ""
                    edits.append(.init(range: lineStart..<totalEnd, text: comment))
                }
            }
            try scanner.scan(line)
            lineStart = totalEnd
        }
        guard scanner.isNeutral else { throw StandMixerError.invalid("Codex config has an unterminated string, array, or inline table. Repair it before applying.") }
        var additions: [String] = []
        for key in ["model", "model_reasoning_effort"] where !found.contains(key) {
            if let value = requested[key] ?? nil { additions.append("\(key) = \(tomlString(value))") }
        }
        var changed = SourceReplacement.applying(edits, to: bytes)
        if !additions.isEmpty {
            var offset = firstTable ?? bytes.count
            for edit in edits where edit.range.upperBound <= (firstTable ?? bytes.count) { offset += edit.bytes.count - edit.range.count }
            let newline = source.contains("\r\n") ? "\r\n" : "\n"
            let prefix = changed[..<offset]
            let leading = prefix.isEmpty || prefix.last == 10 ? "" : newline
            let trailing = firstTable != nil || changed.isEmpty || bytes.last == 10 ? newline : ""
            changed.insert(contentsOf: Array((leading + additions.joined(separator: newline) + trailing).utf8), at: offset)
        }
        return String(decoding: changed, as: UTF8.self)
    }

    static func claudeSettings(_ source: String?, model: String, effort: String?) throws -> String {
        guard model != Route.autoControllerModelID else { return source ?? "" }
        let original = source.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? "{}\n"
        let withModel = try JSONSourceEditor(original).setting(["model"], to: model)
        // The native top-level effortLevel is intentionally preserved. StandMixer owns
        // only the selected model's override, matching Claude's per-model settings.
        return try JSONSourceEditor(withModel).setting(["modelSettings", model, "effortLevel"], to: effort)
    }

    static func tomlString(_ text: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes])
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }
}

private struct SourceReplacement {
    let range: Range<Int>
    let bytes: [UInt8]
    init(range: Range<Int>, text: String) { self.range = range; bytes = Array(text.utf8) }
    static func applying(_ edits: [Self], to source: [UInt8]) -> [UInt8] {
        var result = source
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) { result.replaceSubrange(edit.range, with: edit.bytes) }
        return result
    }
}

private struct TOMLScalar {
    let range: Range<Int>
    let value: String
    let isLiteral: Bool
    let comment: Int?

    init(line: String, after offset: Int, key: String) throws {
        let bytes = Array(line.utf8)
        func invalid() -> StandMixerError { .invalid("Codex \(key) must have one unambiguous single-line string value.") }
        var start = offset
        while start < bytes.count && (bytes[start] == 32 || bytes[start] == 9) { start += 1 }
        guard start < bytes.count, bytes[start] == 34 || bytes[start] == 39 else { throw invalid() }
        let quote = bytes[start]
        guard start + 2 >= bytes.count || bytes[start + 1] != quote || bytes[start + 2] != quote else { throw invalid() }
        var end = start + 1
        while end < bytes.count {
            if bytes[end] == quote { break }
            if bytes[end] == 10 || bytes[end] == 13 { throw invalid() }
            if quote == 34 && bytes[end] == 92 { end += 1 }
            end += 1
        }
        guard end < bytes.count else { throw invalid() }
        range = start..<(end + 1)
        isLiteral = quote == 39
        let inner = String(decoding: bytes[(start + 1)..<end], as: UTF8.self)
        if isLiteral {
            guard inner.unicodeScalars.allSatisfy({ $0.value >= 32 || $0.value == 9 }) else { throw invalid() }
            value = inner
        } else {
            let scalars = Array(inner.unicodeScalars)
            var decoded = String.UnicodeScalarView()
            var index = 0
            while index < scalars.count {
                let scalar = scalars[index]
                guard scalar.value >= 32 || scalar.value == 9 else { throw invalid() }
                if scalar.value != 92 { decoded.append(scalar); index += 1; continue }
                index += 1
                guard index < scalars.count else { throw invalid() }
                let escape = scalars[index].value
                let common: [UInt32: UInt32] = [98: 8, 116: 9, 110: 10, 102: 12, 114: 13, 34: 34, 92: 92]
                if let replacement = common[escape] { decoded.append(UnicodeScalar(replacement)!); index += 1 }
                else if escape == 117 || escape == 85 {
                    let length = escape == 117 ? 4 : 8
                    guard index + length < scalars.count else { throw invalid() }
                    let hexadecimal = String(String.UnicodeScalarView(scalars[(index + 1)...(index + length)]))
                    guard hexadecimal.unicodeScalars.allSatisfy({ (48...57).contains($0.value) || (65...70).contains($0.value) || (97...102).contains($0.value) }),
                          let number = UInt32(hexadecimal, radix: 16), let decodedScalar = UnicodeScalar(number) else { throw invalid() }
                    decoded.append(decodedScalar)
                    index += length + 1
                } else { throw invalid() }
            }
            value = String(decoded)
        }
        var tail = end + 1
        while tail < bytes.count && (bytes[tail] == 32 || bytes[tail] == 9 || bytes[tail] == 13) { tail += 1 }
        guard tail == bytes.count || bytes[tail] == 35 else { throw invalid() }
        comment = tail < bytes.count ? tail : nil
    }
}

/// A validated JSON tree retains UTF-8 source ranges. Only a managed member's
/// value or its immediate comma boundary is replaced; unrelated bytes survive.
struct JSONSourceEditor {
    let bytes: [UInt8]
    private let root: JSONNode

    init(_ source: String) throws {
        let data = Data(source.utf8)
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw StandMixerError.invalid("Claude settings.json must contain a valid JSON object.")
        }
        bytes = Array(data)
        var parser = JSONRangeParser(bytes: bytes)
        root = try parser.parse()
    }

    func setting(_ path: [String], to value: String?) throws -> String {
        var node = root
        for (index, key) in path.enumerated() {
            guard case .object(let members) = node.shape else {
                throw StandMixerError.invalid("Claude \(path.prefix(index).joined(separator: ".")) must be an object; repair it before applying.")
            }
            let matches = members.enumerated().filter { $0.element.key == key }
            guard matches.count <= 1 else { throw StandMixerError.invalid("Claude settings contain duplicate managed \(key) keys; repair them before applying.") }
            guard let (memberIndex, member) = matches.first else {
                guard let value else { return text(bytes) }
                var nested = ConfigEdits.tomlString(value)
                for child in path.dropFirst(index + 1).reversed() { nested = "{\(ConfigEdits.tomlString(child)):\(nested)}" }
                return try inserting(key: key, jsonValue: nested, into: node, members: members)
            }
            if index < path.count - 1 { node = member.value; continue }
            if let value {
                if case .string(let previous) = member.value.shape, previous == value { return text(bytes) }
                return try replacing(member.value.range, with: ConfigEdits.tomlString(value))
            }
            let range: Range<Int>
            if let comma = member.commaAfter { range = member.keyStart..<(comma + 1) }
            else if memberIndex > 0, let comma = members[memberIndex - 1].commaAfter { range = comma..<member.value.range.upperBound }
            else { range = member.keyStart..<member.value.range.upperBound }
            return try replacing(range, with: "")
        }
        return text(bytes)
    }

    func value(at path: [String]) throws -> String? {
        var node = root
        for key in path {
            guard case .object(let members) = node.shape else { throw StandMixerError.invalid("Claude settings path \(path.joined(separator: ".")) must contain objects.") }
            let matches = members.filter { $0.key == key }
            guard matches.count <= 1 else { throw StandMixerError.invalid("Claude settings contain duplicate managed \(key) keys.") }
            guard let member = matches.first else { return nil }
            node = member.value
        }
        return text(Array(bytes[node.range]))
    }

    func settingRaw(_ path: [String], to raw: String?) throws -> String {
        guard let raw else { return try setting(path, to: nil) }
        guard (try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed])) != nil else { throw StandMixerError.invalid("The original native setting is not valid JSON.") }
        var node = root
        for (index, key) in path.enumerated() {
            guard case .object(let members) = node.shape else { throw StandMixerError.invalid("Claude settings path must contain objects.") }
            let matches = members.filter { $0.key == key }
            guard matches.count <= 1 else { throw StandMixerError.invalid("Claude settings contain duplicate managed \(key) keys.") }
            guard let member = matches.first else {
                var nested = raw
                for child in path.dropFirst(index + 1).reversed() { nested = "{\(ConfigEdits.tomlString(child)):\(nested)}" }
                return try inserting(key: key, jsonValue: nested, into: node, members: members)
            }
            if index == path.count - 1 { return try replacing(member.value.range, with: raw) }
            node = member.value
        }
        return text(bytes)
    }

    private func inserting(key: String, jsonValue: String, into node: JSONNode, members: [JSONMember]) throws -> String {
        let encodedKey = ConfigEdits.tomlString(key)
        if let last = members.last {
            let colon = text(Array(bytes[last.keyEnd..<last.value.range.lowerBound]))
            let inside = bytes[(node.range.lowerBound + 1)..<(node.range.upperBound - 1)]
            let separator: String
            if inside.contains(10) {
                let newline = inside.contains(13) ? "\r\n" : "\n"
                var indentStart = last.keyStart
                while indentStart > node.range.lowerBound + 1 && bytes[indentStart - 1] != 10 { indentStart -= 1 }
                let leading = bytes[indentStart..<last.keyStart]
                let indent = leading.allSatisfy { $0 == 32 || $0 == 9 || $0 == 13 } ? text(Array(leading.filter { $0 != 13 })) : "  "
                separator = newline + indent
            } else if members.count > 1, let comma = members[members.count - 2].commaAfter {
                separator = text(Array(bytes[(comma + 1)..<last.keyStart]))
            } else { separator = inside.first == 32 ? " " : "" }
            return try replacing(last.value.range.upperBound..<last.value.range.upperBound, with: "," + separator + encodedKey + colon + jsonValue)
        }
        return try replacing((node.range.lowerBound + 1)..<(node.range.lowerBound + 1), with: encodedKey + ":" + jsonValue)
    }

    private func replacing(_ range: Range<Int>, with replacement: String) throws -> String {
        let output = SourceReplacement.applying([.init(range: range, text: replacement)], to: bytes)
        guard (try? JSONSerialization.jsonObject(with: Data(output))) is [String: Any] else {
            throw StandMixerError.invalid("Claude's managed settings could not be edited safely; repair their structure before applying.")
        }
        return text(output)
    }
    private func text(_ data: [UInt8]) -> String { String(decoding: data, as: UTF8.self) }
}

private struct JSONNode {
    let range: Range<Int>
    let shape: JSONShape
}
private indirect enum JSONShape {
    case object([JSONMember]), string(String), other
}
private struct JSONMember {
    let key: String
    let keyStart: Int
    let keyEnd: Int
    let value: JSONNode
    let commaAfter: Int?
}
private struct JSONRangeParser {
    let bytes: [UInt8]
    var index = 0

    mutating func parse() throws -> JSONNode {
        if bytes.starts(with: [239, 187, 191]) { index = 3 }
        let value = try parseValue(depth: 0)
        whitespace()
        guard index == bytes.count else { throw invalid() }
        return value
    }
    private func invalid() -> StandMixerError { .invalid("Claude's managed JSON paths could not be located unambiguously.") }
    private mutating func whitespace() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
    private mutating func parseString() throws -> (String, Range<Int>) {
        guard index < bytes.count, bytes[index] == 34 else { throw invalid() }
        let start = index
        index += 1
        while index < bytes.count {
            if bytes[index] == 34 {
                index += 1
                guard let value = try? JSONSerialization.jsonObject(with: Data(bytes[start..<index]), options: [.fragmentsAllowed]) as? String else { throw invalid() }
                return (value, start..<index)
            }
            if bytes[index] == 92 { index += 1 }
            index += 1
        }
        throw invalid()
    }
    private mutating func parseValue(depth: Int) throws -> JSONNode {
        guard depth <= 256 else { throw invalid() }
        whitespace()
        guard index < bytes.count else { throw invalid() }
        let start = index
        if bytes[index] == 34 {
            let (value, range) = try parseString()
            return .init(range: range, shape: .string(value))
        }
        if bytes[index] == 123 {
            index += 1
            whitespace()
            var members: [JSONMember] = []
            while index < bytes.count && bytes[index] != 125 {
                let (key, keyRange) = try parseString()
                whitespace()
                guard index < bytes.count, bytes[index] == 58 else { throw invalid() }
                index += 1
                let value = try parseValue(depth: depth + 1)
                whitespace()
                let comma = index < bytes.count && bytes[index] == 44 ? index : nil
                members.append(.init(key: key, keyStart: keyRange.lowerBound, keyEnd: keyRange.upperBound, value: value, commaAfter: comma))
                if comma == nil { break }
                index += 1
                whitespace()
            }
            guard index < bytes.count, bytes[index] == 125 else { throw invalid() }
            index += 1
            return .init(range: start..<index, shape: .object(members))
        }
        if bytes[index] == 91 {
            index += 1
            whitespace()
            while index < bytes.count && bytes[index] != 93 {
                _ = try parseValue(depth: depth + 1)
                whitespace()
                if index < bytes.count, bytes[index] == 44 { index += 1; whitespace() }
                else { break }
            }
            guard index < bytes.count, bytes[index] == 93 else { throw invalid() }
            index += 1
            return .init(range: start..<index, shape: .other)
        }
        while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
        guard index > start else { throw invalid() }
        return .init(range: start..<index, shape: .other)
    }
}

private struct TOMLScanner {
    enum Quote { case none, basic, literal, multiBasic, multiLiteral }
    var quote = Quote.none
    var square = 0
    var curly = 0
    var isNeutral: Bool { quote == .none && square == 0 && curly == 0 }

    mutating func scan(_ line: String) throws {
        let bytes = Array(line.utf8)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            let triple = index + 2 < bytes.count && bytes[index + 1] == byte && bytes[index + 2] == byte
            switch quote {
            case .multiBasic:
                if byte == 92 { index += 2; continue }
                if byte == 34 && triple { quote = .none; index += 3; continue }
            case .multiLiteral:
                if byte == 39 && triple { quote = .none; index += 3; continue }
            case .basic:
                if byte == 92 { index += 2; continue }
                if byte == 34 { quote = .none }
            case .literal:
                if byte == 39 { quote = .none }
            case .none:
                if byte == 35 { return }
                if byte == 34 { quote = triple ? .multiBasic : .basic; if triple { index += 3; continue } }
                else if byte == 39 { quote = triple ? .multiLiteral : .literal; if triple { index += 3; continue } }
                else if byte == 91 { square += 1 }
                else if byte == 93 { square -= 1 }
                else if byte == 123 { curly += 1 }
                else if byte == 125 { curly -= 1 }
                guard square >= 0, curly >= 0 else { throw StandMixerError.invalid("Codex config has unbalanced brackets.") }
            }
            index += 1
        }
        guard quote != .basic, quote != .literal else { throw StandMixerError.invalid("Codex config contains an unterminated single-line string.") }
    }
}

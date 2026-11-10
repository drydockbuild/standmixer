import Foundation

public enum TextDiffLineKind: Sendable {
    case context, addition, removal
}

public struct TextDiffLine: Sendable {
    public let kind: TextDiffLineKind
    public let text: String
    public let oldLineNumber: Int?
    public let newLineNumber: Int?
}

public struct TextDiffHunk: Sendable {
    public let oldStart: Int
    public let oldCount: Int
    public let newStart: Int
    public let newCount: Int
    public let lines: [TextDiffLine]
}

/// A bounded line diff for reviewing settings without repeating unrelated contents.
/// Small edits in large files use Myers' shortest-edit path. Large replacements
/// fall back to a complete, exact replacement of the unmatched region.
public struct TextDiff: Sendable {
    public let hunks: [TextDiffHunk]
    public let addedLineCount: Int
    public let removedLineCount: Int
    public let beforeEndsWithNewline: Bool
    public let afterEndsWithNewline: Bool
    public let hasFinalNewlineChange: Bool
    public let isCoarse: Bool
    public let isUnchanged: Bool

    public init(before: String?, after: String?, contextLines: Int = 3) {
        beforeEndsWithNewline = before?.hasSuffix("\n") == true
        afterEndsWithNewline = after?.hasSuffix("\n") == true
        hasFinalNewlineChange = before != nil && after != nil
            && beforeEndsWithNewline != afterEndsWithNewline
        isUnchanged = before == after
        let old = Self.lines(before ?? "")
        let new = Self.lines(after ?? "")
        let result = Self.operations(old: old, new: new)
        isCoarse = result.coarse
        var oldNumber = 0
        var newNumber = 0
        var lines: [TextDiffLine] = []
        var positions: [(old: Int, new: Int)] = []
        for operation in result.operations {
            positions.append((oldNumber, newNumber))
            switch operation {
            case .context(let text):
                oldNumber += 1; newNumber += 1
                lines.append(.init(kind: .context, text: text, oldLineNumber: oldNumber, newLineNumber: newNumber))
            case .addition(let text):
                newNumber += 1
                lines.append(.init(kind: .addition, text: text, oldLineNumber: nil, newLineNumber: newNumber))
            case .removal(let text):
                oldNumber += 1
                lines.append(.init(kind: .removal, text: text, oldLineNumber: oldNumber, newLineNumber: nil))
            }
        }
        addedLineCount = lines.filter { $0.kind == .addition }.count
        removedLineCount = lines.filter { $0.kind == .removal }.count
        let context = max(0, min(contextLines, 20))
        var ranges: [Range<Int>] = []
        for index in lines.indices where lines[index].kind != .context {
            let range = max(0, index - context)..<min(lines.count, index + context + 1)
            if let last = ranges.last, range.lowerBound <= last.upperBound {
                ranges[ranges.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else { ranges.append(range) }
        }
        hunks = ranges.map { range in
            let content = Array(lines[range])
            let oldCount = content.filter { $0.kind != .addition }.count
            let newCount = content.filter { $0.kind != .removal }.count
            return TextDiffHunk(oldStart: positions[range.lowerBound].old + (oldCount > 0 ? 1 : 0),
                                oldCount: oldCount,
                                newStart: positions[range.lowerBound].new + (newCount > 0 ? 1 : 0),
                                newCount: newCount, lines: content)
        }
    }

    private enum Operation {
        case context(String), addition(String), removal(String)
    }

    private static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var result = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") { result.removeLast() }
        return result
    }

    private static func operations(old: [String], new: [String]) -> (operations: [Operation], coarse: Bool) {
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix,
              old[old.count - suffix - 1] == new[new.count - suffix - 1] { suffix += 1 }
        let oldMiddle = Array(old[prefix..<(old.count - suffix)])
        let newMiddle = Array(new[prefix..<(new.count - suffix)])
        var result = old.prefix(prefix).map(Operation.context)
        var coarse = false
        if oldMiddle.isEmpty { result += newMiddle.map(Operation.addition) }
        else if newMiddle.isEmpty { result += oldMiddle.map(Operation.removal) }
        else if let edits = shortestEdits(old: oldMiddle, new: newMiddle) { result += edits }
        else {
            coarse = true
            result += oldMiddle.map(Operation.removal) + newMiddle.map(Operation.addition)
        }
        result += old.suffix(suffix).map(Operation.context)
        return (result, coarse)
    }

    private static func shortestEdits(old: [String], new: [String]) -> [Operation]? {
        // At most ~4 MiB of integer trace storage, independent of file length.
        let limit = min(old.count + new.count, 512)
        let offset = limit + 1
        var frontier = Array(repeating: 0, count: 2 * limit + 3)
        var trace: [[Int]] = []
        for distance in 0...limit {
            trace.append(frontier)
            for diagonal in stride(from: -distance, through: distance, by: 2) {
                let index = offset + diagonal
                var x: Int
                if diagonal == -distance || (diagonal != distance && frontier[index - 1] < frontier[index + 1]) {
                    x = frontier[index + 1]
                } else { x = frontier[index - 1] + 1 }
                var y = x - diagonal
                while x < old.count, y < new.count, old[x] == new[y] { x += 1; y += 1 }
                frontier[index] = x
                if x >= old.count, y >= new.count {
                    return backtrack(trace: trace, offset: offset, old: old, new: new)
                }
            }
        }
        return nil
    }

    private static func backtrack(trace: [[Int]], offset: Int, old: [String], new: [String]) -> [Operation] {
        var x = old.count
        var y = new.count
        var result: [Operation] = []
        for distance in stride(from: trace.count - 1, through: 0, by: -1) {
            let frontier = trace[distance]
            let diagonal = x - y
            let previousDiagonal: Int
            if diagonal == -distance || (diagonal != distance && frontier[offset + diagonal - 1] < frontier[offset + diagonal + 1]) {
                previousDiagonal = diagonal + 1
            } else { previousDiagonal = diagonal - 1 }
            let previousX = frontier[offset + previousDiagonal]
            let previousY = previousX - previousDiagonal
            while x > previousX, y > previousY {
                x -= 1; y -= 1; result.append(.context(old[x]))
            }
            guard distance > 0 else { break }
            if x == previousX { y -= 1; result.append(.addition(new[y])) }
            else { x -= 1; result.append(.removal(old[x])) }
        }
        return result.reversed()
    }
}

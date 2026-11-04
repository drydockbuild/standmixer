import XCTest
@testable import AgentMixCore

final class TextDiffTests: XCTestCase {
    func testSmallSettingsEditsExcludeUnchangedProjectTables() {
        let tables = (0..<2_000).map { "[projects.\"project-\($0)\"]\ntrust_level = \"trusted\"" }.joined(separator: "\n")
        let before = "model = \"old\"\n\(tables)\nmodel_reasoning_effort = \"low\"\n"
        let after = "model = \"new\"\n\(tables)\nmodel_reasoning_effort = \"ultra\"\n"
        let diff = TextDiff(before: before, after: after)
        XCTAssertEqual(diff.addedLineCount, 2)
        XCTAssertEqual(diff.removedLineCount, 2)
        XCTAssertEqual(diff.hunks.count, 2)
        XCTAssertLessThan(diff.hunks.flatMap(\.lines).count, 20)
        XCTAssertFalse(diff.isCoarse)
        XCTAssertFalse(diff.hunks.flatMap(\.lines).contains { $0.text.contains("project-1000") })
    }

    func testCreatedDeletedEmptyAndFinalNewlineChangesAreExplicit() {
        let created = TextDiff(before: nil, after: "one\ntwo\n")
        XCTAssertEqual(created.addedLineCount, 2)
        XCTAssertEqual(created.hunks.first?.oldStart, 0)
        XCTAssertEqual(created.hunks.first?.newStart, 1)
        let deleted = TextDiff(before: "one\ntwo\n", after: nil)
        XCTAssertEqual(deleted.removedLineCount, 2)
        XCTAssertEqual(deleted.hunks.first?.newStart, 0)
        XCTAssertFalse(TextDiff(before: nil, after: "").isUnchanged)
        XCTAssertTrue(TextDiff(before: "", after: "").isUnchanged)
        let newline = TextDiff(before: "same", after: "same\n")
        XCTAssertTrue(newline.hasFinalNewlineChange)
        XCTAssertFalse(newline.isUnchanged)
        XCTAssertTrue(newline.hunks.isEmpty)
    }

    func testAllEditsRoundTripWithRepeatedLinesAndAccurateLineNumbers() {
        var seed: UInt64 = 0xA6E17
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1
            return Int((seed >> 32) % UInt64(bound))
        }
        for _ in 0..<400 {
            let before = (0..<next(18)).map { _ in String(next(5)) }
            let after = (0..<next(18)).map { _ in String(next(5)) }
            let diff = TextDiff(before: before.joined(separator: "\n"), after: after.joined(separator: "\n"), contextLines: 0)
            var result = before
            for hunk in diff.hunks.reversed() {
                let start = hunk.oldCount == 0 ? hunk.oldStart : hunk.oldStart - 1
                let replacements = hunk.lines.filter { $0.kind != .removal }.map(\.text)
                result.replaceSubrange(start..<(start + hunk.oldCount), with: replacements)
                for line in hunk.lines {
                    if let number = line.oldLineNumber { XCTAssertEqual(before[number - 1], line.text) }
                    if let number = line.newLineNumber { XCTAssertEqual(after[number - 1], line.text) }
                }
            }
            XCTAssertEqual(result, after)
        }
    }

    func testLargeReplacementsRemainCompleteWhenEditBudgetIsExceeded() {
        let old = (0..<800).map { "old-\($0)" }
        let new = (0..<800).map { "new-\($0)" }
        let diff = TextDiff(before: old.joined(separator: "\n"), after: new.joined(separator: "\n"))
        XCTAssertTrue(diff.isCoarse)
        XCTAssertEqual(diff.removedLineCount, 800)
        XCTAssertEqual(diff.addedLineCount, 800)
        XCTAssertEqual(diff.hunks.count, 1)
        XCTAssertEqual(diff.hunks[0].lines.filter { $0.kind == .addition }.map(\.text), new)
    }
}

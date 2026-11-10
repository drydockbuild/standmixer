import Foundation
import XCTest
@testable import StandMixerCore

final class ConfigEditsTests: XCTestCase {
    func testTOMLOnlyChangesRootKeysAndPreservesMultilineText() throws {
        let input = """
        # existing config
        'model' = 'old'
        model_reasoning_effort = "medium"
        note = '''
        [this is text, not a table]
        model = "leave this alone"
        '''
        [tools]
        model = "nested"
        enabled = true
        """
        let output = try ConfigEdits.codexSettings(input, model: "gpt-6.1-sol", effort: "ultra")
        XCTAssertTrue(output.hasPrefix("# existing config\n'model' = 'gpt-6.1-sol'\nmodel_reasoning_effort = \"ultra\"\n"))
        XCTAssertTrue(output.contains("model = \"leave this alone\""))
        XCTAssertTrue(output.contains("[tools]\nmodel = \"nested\"\nenabled = true"))
        XCTAssertFalse(output.contains("'model' = 'old'"))
    }

    func testDuplicateAndAmbiguousTOMLRootValuesAreRefused() {
        XCTAssertThrowsError(try ConfigEdits.codexSettings("model = 'a'\n\"model\" = 'b'\n", model: "gpt-6.1-sol", effort: nil))
        XCTAssertThrowsError(try ConfigEdits.codexSettings("model = '''\nmultiline\n'''\n", model: "gpt-6.1-sol", effort: nil))
        XCTAssertThrowsError(try ConfigEdits.codexSettings("items = [\n", model: "gpt-6.1-sol", effort: nil))
    }

    func testAutoClearsSelectedClaudeEffortAndPreservesOtherModelSettings() throws {
        let input = #"{"modelSettings":{"claude-opus-5-5":{"effortLevel":"high","maxEffortLevel":"max"},"claude-fable-5-1":{"effortLevel":"xhigh"}},"effortLevel":"medium","permissions":{"deny":["Bash(rm *)"]}}"#
        let result = try ConfigEdits.claudeSettings(input, model: "claude-opus-5-5", effort: nil)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        let models = try XCTUnwrap(root["modelSettings"] as? [String: [String: String]])
        XCTAssertNil(models["claude-opus-5-5"]?["effortLevel"])
        XCTAssertEqual(models["claude-opus-5-5"]?["maxEffortLevel"], "max")
        XCTAssertEqual(models["claude-fable-5-1"]?["effortLevel"], "xhigh")
        XCTAssertEqual(root["effortLevel"] as? String, "medium")
        XCTAssertNotNil(root["permissions"])
    }

    func testManagedBlockIsIdempotentAndPreservesSurroundingText() throws {
        let original = "Keep this prefix.\n\n\(ConfigEdits.begin)\nold instructions\n\(ConfigEdits.end)\n\nKeep this suffix."
        let output = try ConfigEdits.managedBlock(in: original, body: "new instructions")
        XCTAssertEqual(output, "Keep this prefix.\n\n\(ConfigEdits.begin)\nnew instructions\n\(ConfigEdits.end)\n\nKeep this suffix.")
        XCTAssertEqual(try ConfigEdits.managedBlock(in: output, body: "new instructions"), output)
    }

    func testBrokenManagedMarkersAreRefused() {
        for source in [ConfigEdits.begin, ConfigEdits.end, "\(ConfigEdits.end)\n\(ConfigEdits.begin)", "\(ConfigEdits.begin)\n\(ConfigEdits.end)\n\(ConfigEdits.begin)\n\(ConfigEdits.end)"] {
            XCTAssertThrowsError(try ConfigEdits.managedBlock(in: source, body: "replacement"))
        }
    }
}

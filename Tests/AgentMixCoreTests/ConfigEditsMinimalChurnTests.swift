import Foundation
import XCTest
@testable import AgentMixCore

final class ConfigEditsMinimalChurnTests: XCTestCase {
    func testTOMLSemanticNoOpPreservesEveryByte() throws {
        let source = #"'model'  = 'gpt-6.1-sol' # user comment"# + "\r\n" + #""model_reasoning_effort" = "ul\u0074ra""# + "\r\n" + "# café\r\n[projects.\"/my/project\"]\r\ntrust_level = 'trusted'"
        XCTAssertEqual(try ConfigEdits.codexSettings(source, model: "gpt-6.1-sol", effort: "ultra"), source)
        let automatic = "model = 'gpt-6.1-sol'\n# no effort override"
        XCTAssertEqual(try ConfigEdits.codexSettings(automatic, model: "gpt-6.1-sol", effort: nil), automatic)
    }

    func testTOMLScalarUpdatesStayInPlaceAndPreserveCommentsAndKeyStyle() throws {
        let source = "# first\n  'model'\t = 'old-root'  # chosen model\nmodel_reasoning_effort=\"low\"\t# chosen effort\nnote = '''\nmodel = 'inside-string'\n'''\n[projects.\"/x\"]\nmodel = 'nested-model'"
        let expected = source.replacingOccurrences(of: "'old-root'", with: "'gpt-6.1-sol'").replacingOccurrences(of: "=\"low\"", with: "=\"ultra\"")
        XCTAssertEqual(try ConfigEdits.codexSettings(source, model: "gpt-6.1-sol", effort: "ultra"), expected)
    }

    func testTOMLAddsMissingRootValueBeforeTablesWithoutMovingOtherKeys() throws {
        let source = "# keep\nmodel = 'gpt-6.1-sol'\n\n[projects.\"/my/project\"]\ntrust_level = 'trusted'\n"
        let expected = "# keep\nmodel = 'gpt-6.1-sol'\n\nmodel_reasoning_effort = \"ultra\"\n[projects.\"/my/project\"]\ntrust_level = 'trusted'\n"
        XCTAssertEqual(try ConfigEdits.codexSettings(source, model: "gpt-6.1-sol", effort: "ultra"), expected)
        XCTAssertEqual(try ConfigEdits.codexSettings("# keep without newline", model: "gpt-6.1-sol", effort: nil), "# keep without newline\nmodel = \"gpt-6.1-sol\"")
    }

    func testTOMLAutoRemovesOnlyEffortAndKeepsItsInlineComment() throws {
        let source = "model='gpt-6.1-sol'\r\n  model_reasoning_effort = 'high'  # my effort note\r\n[example]\r\nmodel_reasoning_effort='nested'"
        XCTAssertEqual(try ConfigEdits.codexSettings(source, model: "gpt-6.1-sol", effort: nil), "model='gpt-6.1-sol'\r\n  # my effort note\r\n[example]\r\nmodel_reasoning_effort='nested'")
        XCTAssertEqual(try ConfigEdits.codexSettings("model='gpt-6.1-sol'\nmodel_reasoning_effort='high'", model: "gpt-6.1-sol", effort: nil), "model='gpt-6.1-sol'\n")
    }

    func testAmbiguousTOMLManagedScalarsAreRefused() {
        for source in ["model = 123", "model = 'old' unexpected", #"model = "bad\qescape""#, #"model = "bad\uD800""#] {
            XCTAssertThrowsError(try ConfigEdits.codexSettings(source, model: "gpt-6.1-sol", effort: nil))
        }
    }

    func testJSONSemanticNoOpPreservesEscapesWhitespaceAndOrdering() throws {
        let source = " \n{\n\t\"permissions\" : {\"model\":\"nested\",\"message\":\"café { \\\"value\\\" }\"},\n\t\"model\" : \"\\u0063laude-opus-5-5\",\n\t\"modelSettings\" : {\"claude-opus-5-5\":{\"effortLevel\":\"hi\\u0067h\",\"other\":1}}\n}"
        XCTAssertEqual(try ConfigEdits.claudeSettings(source, model: "claude-opus-5-5", effort: "high"), source)
        let automatic = #"{"permissions":{"mode":"default"},"model":"claude-opus-5-5","modelSettings":{"claude-opus-5-5":{}}}"#
        XCTAssertEqual(try ConfigEdits.claudeSettings(automatic, model: "claude-opus-5-5", effort: nil), automatic)
    }

    func testJSONTargetsOnlyRootModelAndSelectedModelEffort() throws {
        let source = #"{ "model":"old", "permissions":{"model":"old","effortLevel":"low"}, "modelSettings":{"claude-opus-5-5":{"effortLevel":"low","maxEffortLevel":"max"},"other":{"effortLevel":"low"}}, "env":{"NOTE":"{\"model\":\"old\"}"} }"#
        let expected = #"{ "model":"claude-opus-5-5", "permissions":{"model":"old","effortLevel":"low"}, "modelSettings":{"claude-opus-5-5":{"effortLevel":"xhigh","maxEffortLevel":"max"},"other":{"effortLevel":"low"}}, "env":{"NOTE":"{\"model\":\"old\"}"} }"#
        XCTAssertEqual(try ConfigEdits.claudeSettings(source, model: "claude-opus-5-5", effort: "xhigh"), expected)
    }

    func testJSONAddsOnlyMissingManagedObjectsAndPreservesUnrelatedFormatting() throws {
        let source = "{\n  \"permissions\" : { \"deny\" : [ \"Bash(rm *)\" ] },\n  \"model\" : \"claude-opus-5-5\"\n}\n"
        let result = try ConfigEdits.claudeSettings(source, model: "claude-opus-5-5", effort: "high")
        XCTAssertTrue(result.contains("  \"permissions\" : { \"deny\" : [ \"Bash(rm *)\" ] }"))
        XCTAssertTrue(result.contains("  \"model\" : \"claude-opus-5-5\""))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        let models = try XCTUnwrap(object["modelSettings"] as? [String: [String: String]])
        XCTAssertEqual(models["claude-opus-5-5"]?["effortLevel"], "high")
        XCTAssertEqual(try ConfigEdits.claudeSettings(result, model: "claude-opus-5-5", effort: "high"), result)
    }

    func testJSONAutoRemovesFirstMiddleLastOrOnlyManagedMemberAndKeepsRootEffort() throws {
        for selected in [#"{"effortLevel":"high","keep":1}"#, #"{"a":1,"effortLevel":"high","b":2}"#, #"{"keep":1,"effortLevel":"high"}"#, #"{"effortLevel":"high"}"#] {
            let source = "{\"model\":\"claude-opus-5-5\",\"effortLevel\":\"medium\",\"modelSettings\":{\"claude-opus-5-5\":\(selected),\"other\":{\"effortLevel\":\"low\"}},\"permissions\":{ \"deny\" : [] }}"
            let result = try ConfigEdits.claudeSettings(source, model: "claude-opus-5-5", effort: nil)
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
            let models = try XCTUnwrap(root["modelSettings"] as? [String: [String: Any]])
            XCTAssertNil(models["claude-opus-5-5"]?["effortLevel"])
            XCTAssertEqual(models["other"]?["effortLevel"] as? String, "low")
            XCTAssertEqual(root["effortLevel"] as? String, "medium")
            XCTAssertTrue(result.contains(#""permissions":{ "deny" : [] }"#))
            XCTAssertEqual(try ConfigEdits.claudeSettings(result, model: "claude-opus-5-5", effort: nil), result)
        }
    }

    func testJSONDuplicateManagedPathsAndNonobjectsAreRefused() {
        for source in [
            #"{"model":"a","model":"b"}"#,
            #"{"model":"claude-opus-5-5","modelSettings":{},"modelSettings":{}}"#,
            #"{"modelSettings":{"claude-opus-5-5":{},"claude-opus-5-5":{}}}"#,
            #"{"modelSettings":{"claude-opus-5-5":{"effortLevel":"high","effortLevel":"low"}}}"#,
            #"{"modelSettings":[]}"#,
            #"{"modelSettings":{"claude-opus-5-5":null}}"#
        ] {
            XCTAssertThrowsError(try ConfigEdits.claudeSettings(source, model: "claude-opus-5-5", effort: "high"))
        }
    }
}

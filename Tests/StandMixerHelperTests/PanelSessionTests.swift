import Foundation
import XCTest
@testable import StandMixerHelper

final class PanelSessionTests: XCTestCase {
    func testSessionURLRequiresPrivateLoopbackAndNoOtherData() throws {
        func data(_ url: String) throws -> Data { try JSONSerialization.data(withJSONObject: ["url": url, "pid": 1, "idleTimeoutSeconds": 1800]) }
        let token = String(repeating: "a", count: 43)
        let valid = "http://127.0.0.1:12345/#token=" + token
        XCTAssertEqual(try StandMixerPanelSession.url(in: data(valid)), valid)
        for invalid in ["https://example.com/#token=" + token, "http://localhost:12345/#token=" + token,
                        "http://127.0.0.1:12345/other#token=" + token, "http://127.0.0.1:12345/?query=1#token=" + token,
                        "http://127.0.0.1:12345/#token=short"] {
            XCTAssertThrowsError(try StandMixerPanelSession.url(in: data(invalid)))
        }
        XCTAssertThrowsError(try StandMixerPanelSession.url(in: Data("{\"url\":\"secret\"}".utf8)))
    }
}

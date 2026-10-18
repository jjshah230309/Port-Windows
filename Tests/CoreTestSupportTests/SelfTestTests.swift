import Testing
@testable import CoreTestSupport

@Suite struct SelfTestTests {
    @Test func selfTestPasses() {
        #expect(SelfTest.run() == [])
    }

    @Test func manifestsParse() throws {
        let json = #"{"system":"gb","entries":[{"name":"x","path":"x.gb","sha256":null,"maxFrames":10,"criterion":"serial","expected":"pass"}]}"#
        let m = try JSONDecoderHelper.decode(json)
        #expect(m.entries.count == 1 && m.entries[0].maxFrames == 10)
    }
}

import Foundation
enum JSONDecoderHelper {
    static func decode(_ s: String) throws -> Manifest { try JSONDecoder().decode(Manifest.self, from: Data(s.utf8)) }
}

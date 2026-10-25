import Foundation
import Testing
@testable import CoreTestSupport

@Suite struct SelfTestTests {
    @Test func selfTestPasses() {
        let failures = SelfTest.run()
        #expect(failures.isEmpty, "the self-test failed: \(failures)")
    }

    @Test func everyStandardCheckPassesOnItsOwn() {
        for check in SelfTest.checks {
            #expect(check.body() == nil, "the check \"\(check.name)\" failed")
        }
    }

    @Test func theSelfTestRunsEveryCheck() {
        #expect(SelfTest.checks.count >= 12)
        #expect(SelfTest.checks.map(\.name).allSatisfy { !$0.isEmpty })
    }

    @Test func theChecksAreNamedUniquely() {
        let names = SelfTest.checks.map(\.name)
        #expect(Set(names).count == names.count, "two checks share a name: \(names)")
    }

    @Test func aFailingCheckIsReported() {
        let failing = SelfTest.Check(name: "deliberately failing check") { "expected 1, saw 2" }
        let failures = SelfTest.run(checks: [failing])
        #expect(failures.count == 1)
        #expect(failures[0].contains("deliberately failing check"))
        #expect(failures[0].contains("expected 1, saw 2"))
    }

    @Test func aPassingCheckIsNotReported() {
        let passing = SelfTest.Check(name: "deliberately passing check") { nil }
        #expect(SelfTest.run(checks: [passing]) == [])
    }

    @Test func aFailingCheckDoesNotHideTheOthers() {
        let failing = SelfTest.Check(name: "failing") { "boom" }
        let passing = SelfTest.Check(name: "passing") { nil }
        let failures = SelfTest.run(checks: [failing, passing])
        #expect(failures.count == 1)
        #expect(failures[0].hasPrefix("failing:"))
    }

    @Test func everyFailingCheckIsReported() {
        let checks = [
            SelfTest.Check(name: "first") { "boom" },
            SelfTest.Check(name: "second") { nil },
            SelfTest.Check(name: "third") { "bang" },
        ]
        let failures = SelfTest.run(checks: checks)
        #expect(failures.count == 2)
        #expect(failures[0].hasPrefix("first:"))
        #expect(failures[1].hasPrefix("third:"))
    }

    @Test func theArgumentlessRunUsesTheStandardChecks() {
        #expect(SelfTest.run() == SelfTest.run(checks: SelfTest.checks))
    }

    @Test func manifestsParse() throws {
        let json = #"{"system":"gb","entries":[{"name":"x","path":"x.gb","sha256":null,"maxFrames":10,"criterion":"serial","expected":"pass"}]}"#
        let m = try JSONDecoderHelper.decode(json)
        #expect(m.entries.count == 1 && m.entries[0].maxFrames == 10)
    }
}

enum JSONDecoderHelper {
    static func decode(_ s: String) throws -> Manifest { try JSONDecoder().decode(Manifest.self, from: Data(s.utf8)) }
}

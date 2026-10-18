import Foundation
import CoreTestSupport

let failures = SelfTest.run()
if failures.isEmpty {
    print("core-selftest: all checks passed")
} else {
    for f in failures { print("FAIL: \(f)") }
    exit(1)
}

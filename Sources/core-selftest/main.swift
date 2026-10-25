import Foundation
import CoreTestSupport

let checks = SelfTest.checks
guard !checks.isEmpty else {
    // An empty list would report success without having tested anything.
    print("core-selftest: no checks to run")
    exit(1)
}

let failures = SelfTest.run(checks: checks)

print("core-selftest: \(checks.count) checks ran")
if failures.isEmpty {
    print("core-selftest: all checks passed")
} else {
    for f in failures { print("FAIL: \(f)") }
    print("core-selftest: \(failures.count) of \(checks.count) checks failed")
    exit(1)
}

import XCTest
@testable import CoreChecks

/// 把独立自检程序 CoreChecks 接入 swift test：同一批用例，任一项失败即抛错、本测试失败。
final class CoreChecksXCTests: XCTestCase {
    func testAllCoreChecks() async throws {
        try await CoreChecks.main()
    }
}

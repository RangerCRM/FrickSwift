import XCTest
@testable import FrickSwift

final class FrickSchemaMismatchErrorTests: XCTestCase {
    func test_localizedDescription_namesBothHashesAndServer() {
        let error = FrickSchemaMismatchError(
            expectedSchemaHash: "rangercrm-0.13.0",
            actualSchemaHash: "rangercrm-0.9.0",
            serverURL: URL(string: "http://127.0.0.1:4099/share/invite")
        )
        XCTAssertEqual(
            error.localizedDescription,
            "Frick schema mismatch: client expects rangercrm-0.13.0, server sent rangercrm-0.9.0 (http://127.0.0.1:4099)."
        )
    }

    func test_localizedDescription_withoutServerOrHash() {
        let error = FrickSchemaMismatchError(expectedSchemaHash: "a", actualSchemaHash: nil)
        XCTAssertEqual(error.localizedDescription, "Frick schema mismatch: client expects a, server sent no hash.")
    }
}

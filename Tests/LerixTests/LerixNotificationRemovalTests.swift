import XCTest
@testable import Lerix

final class LerixNotificationRemovalTests: XCTestCase {
    private func removalId(_ userInfo: [AnyHashable: Any]) -> String? {
        LerixNotifications.removalNotificationId(from: userInfo)
    }

    /// Exactly what `apple_notifications.service.ts` `sendRemovalNotification` sends.
    func testBackendDataActionShape() {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["content-available": 1],
            "data": ["action": "remove", "notificationId": "n-123"],
        ]
        XCTAssertEqual(removalId(userInfo), "n-123")
    }

    func testBackendShapeFromJSON() throws {
        let json = #"{"aps":{"content-available":1},"data":{"action":"remove","notificationId":"n-456"}}"#
        let userInfo = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [AnyHashable: Any])
        XCTAssertEqual(removalId(userInfo), "n-456")
    }

    func testLegacyTopLevelCommandShape() {
        XCTAssertEqual(removalId(["command": "remove", "notificationId": "n-789"]), "n-789")
    }

    func testRegularNotificationIsNotRemoval() {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "Hi", "body": "There"]],
            "notificationId": "n-1",
            "metadata": [:] as [String: Any],
        ]
        XCTAssertNil(removalId(userInfo))
    }

    func testOtherDataActionIsIgnored() {
        XCTAssertNil(removalId(["data": ["action": "config_refresh", "notificationId": "n-1"]]))
    }

    func testMissingOrEmptyIdIsIgnored() {
        XCTAssertNil(removalId(["data": ["action": "remove"]]))
        XCTAssertNil(removalId(["data": ["action": "remove", "notificationId": ""]]))
        XCTAssertNil(removalId(["command": "remove"]))
    }
}

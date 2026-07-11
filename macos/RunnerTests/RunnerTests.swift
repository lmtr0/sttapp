import Cocoa
import FlutterMacOS
import XCTest

class RunnerTests: XCTestCase {
  func testPermissionStatusUsesStableChannelSchema() {
    let microphone = FakeMicrophonePermission(statusName: "authorized")
    let accessibility = FakeAccessibilityPermission(isAuthorized: true)
    let handler = MacOSPermissionMethodHandler(
      microphone: microphone,
      accessibility: accessibility
    )
    let call = FlutterMethodCall(methodName: "getStatus", arguments: nil)
    var response: Any?

    handler.handle(call) { response = $0 }

    let status = response as? [String: Any]
    XCTAssertEqual(status?["microphone"] as? String, "authorized")
    XCTAssertEqual(status?["accessibility"] as? Bool, true)
  }

  func testOpenSettingsRejectsMalformedArguments() {
    let handler = MacOSPermissionMethodHandler(
      microphone: FakeMicrophonePermission(statusName: "denied"),
      accessibility: FakeAccessibilityPermission(isAuthorized: false),
      openURL: { _ in true }
    )
    let call = FlutterMethodCall(
      methodName: "openPermissionSettings",
      arguments: NSNull()
    )
    var response: Any?

    handler.handle(call) { response = $0 }

    XCTAssertEqual((response as? FlutterError)?.code, "invalid_arguments")
  }

  func testOpenSettingsRejectsUnknownPermission() {
    var didOpen = false
    let handler = MacOSPermissionMethodHandler(
      microphone: FakeMicrophonePermission(statusName: "denied"),
      accessibility: FakeAccessibilityPermission(isAuthorized: false),
      openURL: { _ in
        didOpen = true
        return true
      }
    )
    let call = FlutterMethodCall(
      methodName: "openPermissionSettings",
      arguments: ["permission": "camera"]
    )
    var response: Any?

    handler.handle(call) { response = $0 }

    XCTAssertEqual((response as? FlutterError)?.code, "invalid_arguments")
    XCTAssertFalse(didOpen)
  }
}

private struct FakeMicrophonePermission: MicrophonePermissionAuthorizing {
  let statusName: String

  func requestAccess(_ completion: @escaping (Bool) -> Void) {
    completion(statusName == "authorized")
  }
}

private struct FakeAccessibilityPermission:
  AccessibilityPermissionAuthorizing
{
  let isAuthorized: Bool

  func requestAccess() -> Bool { isAuthorized }
}

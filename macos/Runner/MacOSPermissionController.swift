import ApplicationServices
import AVFoundation
import Cocoa
import FlutterMacOS

protocol MicrophonePermissionAuthorizing {
  var statusName: String { get }
  func requestAccess(_ completion: @escaping (Bool) -> Void)
}

protocol AccessibilityPermissionAuthorizing {
  var isAuthorized: Bool { get }
  func requestAccess() -> Bool
}

private struct SystemMicrophonePermissionAuthorizer: MicrophonePermissionAuthorizing {
  var statusName: String {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .notDetermined:
      return "notDetermined"
    case .denied:
      return "denied"
    case .restricted:
      return "restricted"
    case .authorized:
      return "authorized"
    @unknown default:
      return "unavailable"
    }
  }

  func requestAccess(_ completion: @escaping (Bool) -> Void) {
    AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
  }
}

private struct SystemAccessibilityPermissionAuthorizer:
  AccessibilityPermissionAuthorizing
{
  var isAuthorized: Bool { AXIsProcessTrusted() }

  func requestAccess() -> Bool {
    let options = [
      kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
    ] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
  }
}

final class MacOSPermissionMethodHandler {
  init(
    microphone: MicrophonePermissionAuthorizing,
    accessibility: AccessibilityPermissionAuthorizing,
    openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
  ) {
    self.microphone = microphone
    self.accessibility = accessibility
    self.openURL = openURL
  }

  private let microphone: MicrophonePermissionAuthorizing
  private let accessibility: AccessibilityPermissionAuthorizing
  private let openURL: (URL) -> Bool

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getStatus":
      result(statusDictionary())
    case "requestMicrophone":
      microphone.requestAccess { [weak self] _ in
        DispatchQueue.main.async {
          guard let self else {
            result(
              FlutterError(
                code: "unavailable",
                message: "The permission controller was released.",
                details: nil
              ))
            return
          }
          result(self.statusDictionary())
        }
      }
    case "requestAccessibility":
      _ = accessibility.requestAccess()
      result(statusDictionary())
    case "openPermissionSettings":
      openPermissionSettings(call, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func statusDictionary() -> [String: Any] {
    [
      "microphone": microphone.statusName,
      "accessibility": accessibility.isAuthorized,
    ]
  }

  private func openPermissionSettings(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    guard let arguments = call.arguments as? [String: Any],
      let permission = arguments["permission"] as? String
    else {
      result(
        FlutterError(
          code: "invalid_arguments",
          message: "Expected a permission argument.",
          details: nil
        ))
      return
    }

    let pane: String
    switch permission {
    case "microphone":
      pane = "Privacy_Microphone"
    case "accessibility":
      pane = "Privacy_Accessibility"
    default:
      result(
        FlutterError(
          code: "invalid_arguments",
          message: "Unknown permission: \(permission)",
          details: nil
        ))
      return
    }

    guard let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"
    ), openURL(url) else {
      result(
        FlutterError(
          code: "open_settings_failed",
          message: "Could not open Privacy & Security settings.",
          details: nil
        ))
      return
    }
    result(nil)
  }
}

final class MacOSPermissionController {
  init(binaryMessenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "com.taresz.sttapp/permissions",
      binaryMessenger: binaryMessenger
    )
    let methodHandler = MacOSPermissionMethodHandler(
      microphone: SystemMicrophonePermissionAuthorizer(),
      accessibility: SystemAccessibilityPermissionAuthorizer()
    )
    handler = methodHandler
    channel.setMethodCallHandler { [methodHandler] call, result in
      methodHandler.handle(call, result: result)
    }
  }

  private let channel: FlutterMethodChannel
  private let handler: MacOSPermissionMethodHandler
}

import Cocoa
import Carbon
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var permissionController: MacOSPermissionController?
  private var globalShortcutsController: MacOSGlobalShortcutsController?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    permissionController = MacOSPermissionController(
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    globalShortcutsController = MacOSGlobalShortcutsController(
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )

    super.awakeFromNib()
  }
}

private let sttappHotKeyEventHandler: EventHandlerUPP = {
  _, event, userData in
  guard let event, let userData else {
    return OSStatus(eventNotHandledErr)
  }
  let controller = Unmanaged<MacOSGlobalShortcutsController>
    .fromOpaque(userData)
    .takeUnretainedValue()
  return controller.handleCarbonEvent(event)
}

private final class MacOSGlobalShortcutsController:
  NSObject,
  FlutterStreamHandler
{
  private struct Registration {
    let reference: EventHotKeyRef
  }

  init(binaryMessenger: FlutterBinaryMessenger) {
    methodChannel = FlutterMethodChannel(
      name: "com.taresz.sttapp/global_shortcuts",
      binaryMessenger: binaryMessenger
    )
    eventChannel = FlutterEventChannel(
      name: "com.taresz.sttapp/global_shortcuts/events",
      binaryMessenger: binaryMessenger
    )
    super.init()
    methodChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(
          FlutterError(
            code: "unavailable",
            message: "The global shortcut controller was released.",
            details: nil
          ))
        return
      }
      self.handle(call, result: result)
    }
    eventChannel.setStreamHandler(self)
  }

  deinit {
    unregisterAll()
    if let eventHandler {
      RemoveEventHandler(eventHandler)
    }
  }

  private let methodChannel: FlutterMethodChannel
  private let eventChannel: FlutterEventChannel
  private var eventSink: FlutterEventSink?
  private var eventHandler: EventHandlerRef?
  private var registrations: [String: Registration] = [:]
  private var shortcutIdsByNativeId: [UInt32: String] = [:]
  private var nextNativeId: UInt32 = 1
  private let signature: OSType = 0x53545441 // "STTA"

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  fileprivate func handleCarbonEvent(_ event: EventRef) -> OSStatus {
    var hotKeyId = EventHotKeyID()
    let status = GetEventParameter(
      event,
      EventParamName(kEventParamDirectObject),
      EventParamType(typeEventHotKeyID),
      nil,
      MemoryLayout<EventHotKeyID>.size,
      nil,
      &hotKeyId
    )
    guard status == noErr,
      hotKeyId.signature == signature,
      let shortcutId = shortcutIdsByNativeId[hotKeyId.id]
    else {
      return status == noErr ? OSStatus(eventNotHandledErr) : status
    }

    eventSink?([
      "id": shortcutId,
      "timestamp": Int64(ProcessInfo.processInfo.systemUptime * 1000),
    ])
    return noErr
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "initialize":
      initialize(call, result: result)
    case "dispose":
      unregisterAll()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func initialize(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    unregisterAll()

    guard let arguments = call.arguments as? [String: Any],
      let shortcuts = arguments["shortcuts"] as? [[String: Any]],
      !shortcuts.isEmpty
    else {
      result(
        FlutterError(
          code: "invalid_arguments",
          message: "Expected at least one global shortcut.",
          details: nil
        ))
      return
    }

    let handlerStatus = installEventHandlerIfNeeded()
    guard handlerStatus == noErr else {
      result(
        FlutterError(
          code: "registration_failed",
          message: "macOS could not install the global shortcut event handler.",
          details: ["nativeErrorCode": handlerStatus]
        ))
      return
    }

    var registeredShortcutIds: [String] = []
    var seenShortcutIds = Set<String>()
    for shortcut in shortcuts {
      guard let shortcutId = shortcut["id"] as? String,
        !shortcutId.isEmpty,
        seenShortcutIds.insert(shortcutId).inserted,
        let keyId = shortcut["keyId"] as? String,
        let keyCode = carbonKeyCode(for: keyId),
        let modifierNames = shortcut["modifiers"] as? [String],
        let modifiers = carbonModifiers(for: modifierNames)
      else {
        unregisterAll()
        result(
          FlutterError(
            code: "invalid_arguments",
            message: "Received an invalid global shortcut definition.",
            details: nil
          ))
        return
      }

      let nativeId = nextNativeId
      nextNativeId += 1
      var reference: EventHotKeyRef?
      let hotKeyId = EventHotKeyID(signature: signature, id: nativeId)
      let status = RegisterEventHotKey(
        keyCode,
        modifiers,
        hotKeyId,
        GetEventDispatcherTarget(),
        0,
        &reference
      )
      guard status == noErr, let reference else {
        unregisterAll()
        result(
          FlutterError(
            code: "registration_failed",
            message:
              "macOS rejected the global shortcut. It may already be in use or reserved by the system.",
            details: [
              "shortcutId": shortcutId,
              "nativeErrorCode": status,
            ]
          ))
        return
      }

      registrations[shortcutId] = Registration(
        reference: reference
      )
      shortcutIdsByNativeId[nativeId] = shortcutId
      registeredShortcutIds.append(shortcutId)
    }

    result(["registeredShortcutIds": registeredShortcutIds])
  }

  private func installEventHandlerIfNeeded() -> OSStatus {
    if eventHandler != nil {
      return noErr
    }
    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )
    return InstallEventHandler(
      GetEventDispatcherTarget(),
      sttappHotKeyEventHandler,
      1,
      &eventType,
      Unmanaged.passUnretained(self).toOpaque(),
      &eventHandler
    )
  }

  private func unregisterAll() {
    for registration in registrations.values {
      UnregisterEventHotKey(registration.reference)
    }
    registrations.removeAll()
    shortcutIdsByNativeId.removeAll()
    nextNativeId = 1
  }

  private func carbonModifiers(for names: [String]) -> UInt32? {
    var modifiers: UInt32 = 0
    for name in names {
      switch name {
      case "alt":
        modifiers |= UInt32(optionKey)
      case "capsLock":
        modifiers |= UInt32(alphaLock)
      case "control":
        modifiers |= UInt32(controlKey)
      case "fn":
        modifiers |= UInt32(kEventKeyModifierFnMask)
      case "meta":
        modifiers |= UInt32(cmdKey)
      case "shift":
        modifiers |= UInt32(shiftKey)
      default:
        return nil
      }
    }
    return modifiers
  }

  private func carbonKeyCode(for keyId: String) -> UInt32? {
    switch keyId.lowercased() {
    case "f1": return UInt32(kVK_F1)
    case "f2": return UInt32(kVK_F2)
    case "f3": return UInt32(kVK_F3)
    case "f4": return UInt32(kVK_F4)
    case "f5": return UInt32(kVK_F5)
    case "f6": return UInt32(kVK_F6)
    case "f7": return UInt32(kVK_F7)
    case "f8": return UInt32(kVK_F8)
    case "f9": return UInt32(kVK_F9)
    case "f10": return UInt32(kVK_F10)
    case "f11": return UInt32(kVK_F11)
    case "f12": return UInt32(kVK_F12)
    default: return nil
    }
  }
}

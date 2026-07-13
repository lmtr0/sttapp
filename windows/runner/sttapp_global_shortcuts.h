#ifndef RUNNER_STTAPP_GLOBAL_SHORTCUTS_H_
#define RUNNER_STTAPP_GLOBAL_SHORTCUTS_H_

#include <windows.h>

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/method_channel.h>

#include <map>
#include <memory>
#include <string>
#include <vector>

class SttappGlobalShortcuts {
public:
  SttappGlobalShortcuts(flutter::BinaryMessenger *messenger, HWND window);
  ~SttappGlobalShortcuts();

  SttappGlobalShortcuts(const SttappGlobalShortcuts &) = delete;
  SttappGlobalShortcuts &operator=(const SttappGlobalShortcuts &) = delete;

  bool HandleHotKey(WPARAM hotkey_id);

private:
  struct Registration {
    int native_id;
  };

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void Initialize(
      const flutter::MethodCall<flutter::EncodableValue> &call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void UnregisterAll();

  HWND window_;
  int next_native_id_ = 1;
  std::vector<Registration> registrations_;
  std::map<int, std::string> shortcut_ids_by_native_id_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      method_channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>>
      event_channel_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> event_sink_;
};

#endif // RUNNER_STTAPP_GLOBAL_SHORTCUTS_H_

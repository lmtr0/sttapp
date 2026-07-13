#include "sttapp_global_shortcuts.h"

#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <optional>
#include <set>
#include <utility>

namespace {

constexpr char kMethodChannelName[] = "com.taresz.sttapp/global_shortcuts";
constexpr char kEventChannelName[] =
    "com.taresz.sttapp/global_shortcuts/events";

const flutter::EncodableValue *FindValue(const flutter::EncodableMap &map,
                                         const char *key) {
  const auto iterator = map.find(flutter::EncodableValue(key));
  return iterator == map.end() ? nullptr : &iterator->second;
}

const std::string *StringValue(const flutter::EncodableMap &map,
                               const char *key) {
  const auto *value = FindValue(map, key);
  return value == nullptr ? nullptr : std::get_if<std::string>(value);
}

std::optional<UINT> VirtualKeyForId(const std::string &key_id) {
  if (key_id.size() < 2 ||
      std::tolower(static_cast<unsigned char>(key_id.front())) != 'f') {
    return std::nullopt;
  }
  try {
    const int function_key = std::stoi(key_id.substr(1));
    if (function_key < 1 || function_key > 12) {
      return std::nullopt;
    }
    return static_cast<UINT>(VK_F1 + function_key - 1);
  } catch (...) {
    return std::nullopt;
  }
}

std::optional<UINT> ModifiersFromValue(const flutter::EncodableValue *value) {
  const auto *values =
      value == nullptr ? nullptr : std::get_if<flutter::EncodableList>(value);
  if (values == nullptr) {
    return std::nullopt;
  }

  UINT modifiers = 0;
  for (const auto &item : *values) {
    const auto *modifier = std::get_if<std::string>(&item);
    if (modifier == nullptr) {
      return std::nullopt;
    }
    if (*modifier == "alt") {
      modifiers |= MOD_ALT;
    } else if (*modifier == "control") {
      modifiers |= MOD_CONTROL;
    } else if (*modifier == "meta") {
      modifiers |= MOD_WIN;
    } else if (*modifier == "shift") {
      modifiers |= MOD_SHIFT;
    } else {
      return std::nullopt;
    }
  }
  return modifiers;
}

flutter::EncodableMap ErrorDetails(const std::string &shortcut_id,
                                   DWORD native_error_code) {
  flutter::EncodableMap details;
  details[flutter::EncodableValue("shortcutId")] =
      flutter::EncodableValue(shortcut_id);
  details[flutter::EncodableValue("nativeErrorCode")] =
      flutter::EncodableValue(static_cast<int64_t>(native_error_code));
  return details;
}

} // namespace

SttappGlobalShortcuts::SttappGlobalShortcuts(
    flutter::BinaryMessenger *messenger, HWND window)
    : window_(window) {
  method_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, kMethodChannelName,
          &flutter::StandardMethodCodec::GetInstance());
  method_channel_->SetMethodCallHandler([this](const auto &call, auto result) {
    HandleMethodCall(call, std::move(result));
  });

  event_channel_ =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          messenger, kEventChannelName,
          &flutter::StandardMethodCodec::GetInstance());
  auto stream_handler = std::make_unique<flutter::StreamHandlerFunctions<>>(
      [this](const flutter::EncodableValue *,
             std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>
                 &&events) {
        event_sink_ = std::move(events);
        return std::unique_ptr<
            flutter::StreamHandlerError<flutter::EncodableValue>>();
      },
      [this](const flutter::EncodableValue *) {
        event_sink_.reset();
        return std::unique_ptr<
            flutter::StreamHandlerError<flutter::EncodableValue>>();
      });
  event_channel_->SetStreamHandler(std::move(stream_handler));
}

SttappGlobalShortcuts::~SttappGlobalShortcuts() { UnregisterAll(); }

bool SttappGlobalShortcuts::HandleHotKey(WPARAM hotkey_id) {
  const auto iterator =
      shortcut_ids_by_native_id_.find(static_cast<int>(hotkey_id));
  if (iterator == shortcut_ids_by_native_id_.end()) {
    return false;
  }

  if (event_sink_ != nullptr) {
    flutter::EncodableMap event;
    event[flutter::EncodableValue("id")] =
        flutter::EncodableValue(iterator->second);
    event[flutter::EncodableValue("timestamp")] =
        flutter::EncodableValue(static_cast<int64_t>(GetTickCount64()));
    event_sink_->Success(flutter::EncodableValue(event));
  }
  return true;
}

void SttappGlobalShortcuts::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() == "initialize") {
    Initialize(call, std::move(result));
  } else if (call.method_name() == "dispose") {
    UnregisterAll();
    result->Success();
  } else {
    result->NotImplemented();
  }
}

void SttappGlobalShortcuts::Initialize(
    const flutter::MethodCall<flutter::EncodableValue> &call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  UnregisterAll();

  const auto *arguments =
      call.arguments() == nullptr
          ? nullptr
          : std::get_if<flutter::EncodableMap>(call.arguments());
  const auto *shortcuts_value =
      arguments == nullptr ? nullptr : FindValue(*arguments, "shortcuts");
  const auto *shortcuts =
      shortcuts_value == nullptr
          ? nullptr
          : std::get_if<flutter::EncodableList>(shortcuts_value);
  if (shortcuts == nullptr || shortcuts->empty()) {
    result->Error("invalid_arguments",
                  "Expected at least one global shortcut.");
    return;
  }

  flutter::EncodableList registered_ids;
  std::set<std::string> seen_ids;
  for (const auto &item : *shortcuts) {
    const auto *shortcut = std::get_if<flutter::EncodableMap>(&item);
    const std::string *shortcut_id =
        shortcut == nullptr ? nullptr : StringValue(*shortcut, "id");
    const std::string *key_id =
        shortcut == nullptr ? nullptr : StringValue(*shortcut, "keyId");
    const auto virtual_key =
        key_id == nullptr ? std::nullopt : VirtualKeyForId(*key_id);
    const auto modifiers =
        shortcut == nullptr
            ? std::nullopt
            : ModifiersFromValue(FindValue(*shortcut, "modifiers"));
    if (shortcut_id == nullptr || shortcut_id->empty() ||
        !seen_ids.insert(*shortcut_id).second || !virtual_key.has_value() ||
        !modifiers.has_value()) {
      UnregisterAll();
      result->Error("invalid_arguments",
                    "Received an invalid global shortcut definition.");
      return;
    }

    const int native_id = next_native_id_++;
    SetLastError(ERROR_SUCCESS);
    if (!RegisterHotKey(window_, native_id, *modifiers, *virtual_key)) {
      const DWORD error_code = GetLastError();
      const auto details = ErrorDetails(*shortcut_id, error_code);
      UnregisterAll();
      result->Error("registration_failed",
                    "Windows rejected the global shortcut. It may already be "
                    "in use or reserved by the system.",
                    flutter::EncodableValue(details));
      return;
    }

    registrations_.push_back({native_id});
    shortcut_ids_by_native_id_[native_id] = *shortcut_id;
    registered_ids.emplace_back(*shortcut_id);
  }

  flutter::EncodableMap response;
  response[flutter::EncodableValue("registeredShortcutIds")] =
      flutter::EncodableValue(registered_ids);
  result->Success(flutter::EncodableValue(response));
}

void SttappGlobalShortcuts::UnregisterAll() {
  for (const auto &registration : registrations_) {
    UnregisterHotKey(window_, registration.native_id);
  }
  registrations_.clear();
  shortcut_ids_by_native_id_.clear();
  next_native_id_ = 1;
}

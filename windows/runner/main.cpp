#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <cstdlib>
#include <exception>
#include <string>

#include "flutter_window.h"
#include "utils.h"

namespace {

std::wstring GetLogDirectoryPath() {
  wchar_t buffer[MAX_PATH];
  DWORD length = ::GetEnvironmentVariableW(L"LOCALAPPDATA", buffer, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) {
    length = ::GetEnvironmentVariableW(L"APPDATA", buffer, MAX_PATH);
  }
  if (length == 0 || length >= MAX_PATH) {
    length = ::GetTempPathW(MAX_PATH, buffer);
  }

  std::wstring directory(buffer, length);
  while (!directory.empty() &&
         (directory.back() == L'\\' || directory.back() == L'/')) {
    directory.pop_back();
  }
  return directory + L"\\sttapp";
}

std::string WideToUtf8(const std::wstring& text) {
  if (text.empty()) {
    return {};
  }
  int size = ::WideCharToMultiByte(CP_UTF8, 0, text.data(),
                                  static_cast<int>(text.size()), nullptr, 0,
                                  nullptr, nullptr);
  if (size <= 0) {
    return {};
  }
  std::string result(size, '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
                        result.data(), size, nullptr, nullptr);
  return result;
}

void LogStartupEvent(const std::wstring& message) {
  ::OutputDebugStringW((L"sttapp: " + message + L"\n").c_str());

  std::wstring directory = GetLogDirectoryPath();
  ::CreateDirectoryW(directory.c_str(), nullptr);
  std::wstring path = directory + L"\\startup.log";

  SYSTEMTIME time;
  ::GetLocalTime(&time);
  wchar_t timestamp[64];
  swprintf_s(timestamp, L"[%04d-%02d-%02dT%02d:%02d:%02d.%03d] ", time.wYear,
             time.wMonth, time.wDay, time.wHour, time.wMinute, time.wSecond,
             time.wMilliseconds);

  std::string entry = WideToUtf8(std::wstring(timestamp) + message + L"\r\n");
  HANDLE file = ::CreateFileW(path.c_str(), FILE_APPEND_DATA,
                              FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                              OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return;
  }

  DWORD written = 0;
  ::WriteFile(file, entry.data(), static_cast<DWORD>(entry.size()), &written,
              nullptr);
  ::CloseHandle(file);
}

LONG WINAPI HandleUnhandledException(EXCEPTION_POINTERS* exception_info) {
  DWORD code = exception_info && exception_info->ExceptionRecord
                   ? exception_info->ExceptionRecord->ExceptionCode
                   : 0;
  wchar_t message[128];
  swprintf_s(message, L"Unhandled native exception 0x%08X", code);
  LogStartupEvent(message);
  return EXCEPTION_EXECUTE_HANDLER;
}

void HandleTerminate() {
  LogStartupEvent(L"Unhandled native C++ exception");
  std::abort();
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  ::SetUnhandledExceptionFilter(HandleUnhandledException);
  std::set_terminate(HandleTerminate);
  LogStartupEvent(L"Windows runner startup begin");

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  HRESULT com_result = ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  if (FAILED(com_result)) {
    wchar_t message[128];
    swprintf_s(message, L"CoInitializeEx failed 0x%08X",
               static_cast<unsigned int>(com_result));
    LogStartupEvent(message);
    return EXIT_FAILURE;
  }
  LogStartupEvent(L"COM initialized");

  flutter::DartProject project(L"data");
  LogStartupEvent(L"Flutter DartProject created");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"sttapp", origin, size)) {
    LogStartupEvent(L"Flutter window creation failed");
    ::CoUninitialize();
    return EXIT_FAILURE;
  }
  LogStartupEvent(L"Flutter window created");
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  LogStartupEvent(L"Windows runner shutdown");
  return EXIT_SUCCESS;
}

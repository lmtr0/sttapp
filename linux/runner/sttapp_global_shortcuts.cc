#include "sttapp_global_shortcuts.h"

#include <gio/gio.h>
#include <glib.h>

#include <algorithm>
#include <cstring>
#include <string>
#include <vector>

namespace {

constexpr char kMethodChannelName[] = "com.taresz.sttapp/global_shortcuts";
constexpr char kEventChannelName[] =
    "com.taresz.sttapp/global_shortcuts/events";
constexpr char kPortalBusName[] = "org.freedesktop.portal.Desktop";
constexpr char kPortalObjectPath[] = "/org/freedesktop/portal/desktop";
constexpr char kGlobalShortcutsInterface[] =
    "org.freedesktop.portal.GlobalShortcuts";
constexpr char kRequestInterface[] = "org.freedesktop.portal.Request";
constexpr char kSessionInterface[] = "org.freedesktop.portal.Session";

struct ShortcutSpec {
  std::string id;
  std::string description;
  std::string preferred_trigger;
};

struct GlobalShortcutsPlugin {
  FlMethodChannel* method_channel = nullptr;
  FlEventChannel* event_channel = nullptr;
  GDBusConnection* connection = nullptr;
  GCancellable* cancellable = nullptr;
  gchar* session_handle = nullptr;
  guint activated_subscription = 0;
  gboolean events_listening = FALSE;
  gboolean initialized = FALSE;
  guint token_counter = 0;
};

struct PendingInitialize {
  GlobalShortcutsPlugin* plugin = nullptr;
  FlMethodCall* method_call = nullptr;
  std::vector<ShortcutSpec> shortcuts;
};

enum class RequestKind {
  kCreateSession,
  kListShortcuts,
  kBindShortcuts,
};

struct PortalRequest {
  GlobalShortcutsPlugin* plugin = nullptr;
  PendingInitialize* pending = nullptr;
  RequestKind kind = RequestKind::kCreateSession;
  gchar* handle = nullptr;
  guint subscription_id = 0;
};

std::vector<ShortcutSpec> default_shortcuts() {
  return {
      {"toggle-normal", "Start or stop capture and paste normally", "F8"},
      {"toggle-plain", "Start or stop capture and paste as plain text",
       "SHIFT+F8"},
  };
}

const gchar* fl_value_string_or_null(FlValue* value) {
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_STRING) {
    return nullptr;
  }
  return fl_value_get_string(value);
}

std::vector<ShortcutSpec> parse_shortcuts(FlValue* args) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return default_shortcuts();
  }

  FlValue* shortcuts_value = fl_value_lookup_string(args, "shortcuts");
  if (shortcuts_value == nullptr ||
      fl_value_get_type(shortcuts_value) != FL_VALUE_TYPE_LIST) {
    return default_shortcuts();
  }

  std::vector<ShortcutSpec> shortcuts;
  const size_t length = fl_value_get_length(shortcuts_value);
  for (size_t index = 0; index < length; ++index) {
    FlValue* item = fl_value_get_list_value(shortcuts_value, index);
    if (item == nullptr || fl_value_get_type(item) != FL_VALUE_TYPE_MAP) {
      continue;
    }

    const gchar* id = fl_value_string_or_null(fl_value_lookup_string(item, "id"));
    const gchar* description =
        fl_value_string_or_null(fl_value_lookup_string(item, "description"));
    const gchar* preferred_trigger = fl_value_string_or_null(
        fl_value_lookup_string(item, "preferredTrigger"));
    if (id == nullptr || description == nullptr ||
        preferred_trigger == nullptr) {
      continue;
    }

    shortcuts.push_back({id, description, preferred_trigger});
  }

  return shortcuts.empty() ? default_shortcuts() : shortcuts;
}

gchar* next_token(GlobalShortcutsPlugin* plugin, const char* purpose) {
  plugin->token_counter += 1;
  return g_strdup_printf("sttapp_%s_%u", purpose, plugin->token_counter);
}

void respond_success(FlMethodCall* method_call) {
  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond_success(method_call, nullptr, &error)) {
    g_warning("Failed to send global shortcuts success response: %s",
              error->message);
  }
}

void respond_error(FlMethodCall* method_call,
                   const char* code,
                   const char* message) {
  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond_error(method_call, code, message, nullptr,
                                    &error)) {
    g_warning("Failed to send global shortcuts error response: %s",
              error->message);
  }
}

void free_pending_initialize(PendingInitialize* pending) {
  if (pending == nullptr) {
    return;
  }
  g_clear_object(&pending->method_call);
  delete pending;
}

void finish_initialize_success(PendingInitialize* pending) {
  pending->plugin->initialized = TRUE;
  respond_success(pending->method_call);
  free_pending_initialize(pending);
}

void finish_initialize_error(PendingInitialize* pending,
                             const char* code,
                             const char* message);

void close_session(GlobalShortcutsPlugin* plugin) {
  if (plugin->activated_subscription != 0 && plugin->connection != nullptr) {
    g_dbus_connection_signal_unsubscribe(plugin->connection,
                                         plugin->activated_subscription);
    plugin->activated_subscription = 0;
  }

  if (plugin->session_handle != nullptr && plugin->connection != nullptr) {
    g_autoptr(GError) error = nullptr;
    g_dbus_connection_call_sync(
        plugin->connection, kPortalBusName, plugin->session_handle,
        kSessionInterface, "Close", nullptr, nullptr, G_DBUS_CALL_FLAGS_NONE,
        -1, nullptr, &error);
    if (error != nullptr) {
      g_warning("Failed to close global shortcuts portal session: %s",
                error->message);
    }
  }

  g_clear_pointer(&plugin->session_handle, g_free);
  plugin->initialized = FALSE;
}

void finish_initialize_error(PendingInitialize* pending,
                             const char* code,
                             const char* message) {
  close_session(pending->plugin);
  respond_error(pending->method_call, code, message);
  free_pending_initialize(pending);
}

gboolean ensure_connection(GlobalShortcutsPlugin* plugin, GError** error) {
  if (plugin->connection != nullptr) {
    return TRUE;
  }

  plugin->connection = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, error);
  return plugin->connection != nullptr;
}

void destroy_portal_request(gpointer data) {
  auto* request = static_cast<PortalRequest*>(data);
  g_clear_pointer(&request->handle, g_free);
  delete request;
}

void wait_for_request(GlobalShortcutsPlugin* plugin,
                      PendingInitialize* pending,
                      RequestKind kind,
                      const char* request_handle,
                      GDBusSignalCallback callback) {
  auto* request = new PortalRequest();
  request->plugin = plugin;
  request->pending = pending;
  request->kind = kind;
  request->handle = g_strdup(request_handle);

  request->subscription_id = g_dbus_connection_signal_subscribe(
      plugin->connection, kPortalBusName, kRequestInterface, "Response",
      request->handle, nullptr, G_DBUS_SIGNAL_FLAGS_NONE, callback, request,
      destroy_portal_request);
}

bool response_has_all_shortcuts(GVariant* results,
                                const std::vector<ShortcutSpec>& expected) {
  GVariant* shortcuts = g_variant_lookup_value(
      results, "shortcuts", G_VARIANT_TYPE("a(sa{sv})"));
  if (shortcuts == nullptr) {
    return false;
  }

  std::vector<std::string> seen;
  GVariantIter iter;
  g_variant_iter_init(&iter, shortcuts);

  const gchar* id = nullptr;
  GVariant* properties = nullptr;
  while (g_variant_iter_next(&iter, "(&s@a{sv})", &id, &properties)) {
    seen.emplace_back(id);
    g_variant_unref(properties);
  }
  g_variant_unref(shortcuts);

  return std::all_of(expected.begin(), expected.end(),
                     [&seen](const ShortcutSpec& shortcut) {
                       return std::find(seen.begin(), seen.end(),
                                        shortcut.id) != seen.end();
                     });
}

void send_shortcut_event(GlobalShortcutsPlugin* plugin,
                         const char* shortcut_id,
                         guint64 timestamp) {
  if (!plugin->events_listening) {
    return;
  }

  g_autoptr(FlValue) event = fl_value_new_map();
  fl_value_set_string_take(event, "id", fl_value_new_string(shortcut_id));
  fl_value_set_string_take(event, "timestamp",
                           fl_value_new_int(static_cast<int64_t>(timestamp)));

  g_autoptr(GError) error = nullptr;
  if (!fl_event_channel_send(plugin->event_channel, event, nullptr, &error)) {
    g_warning("Failed to send global shortcut event: %s", error->message);
  }
}

void activated_cb(GDBusConnection* connection,
                  const gchar* sender_name,
                  const gchar* object_path,
                  const gchar* interface_name,
                  const gchar* signal_name,
                  GVariant* parameters,
                  gpointer user_data) {
  auto* plugin = static_cast<GlobalShortcutsPlugin*>(user_data);

  const gchar* session_handle = nullptr;
  const gchar* shortcut_id = nullptr;
  guint64 timestamp = 0;
  GVariant* options = nullptr;
  g_variant_get(parameters, "(&o&st@a{sv})", &session_handle, &shortcut_id,
                &timestamp, &options);

  if (g_strcmp0(session_handle, plugin->session_handle) == 0) {
    send_shortcut_event(plugin, shortcut_id, timestamp);
  }

  g_variant_unref(options);
}

void subscribe_activation(GlobalShortcutsPlugin* plugin) {
  if (plugin->activated_subscription != 0) {
    return;
  }

  plugin->activated_subscription = g_dbus_connection_signal_subscribe(
      plugin->connection, kPortalBusName, kGlobalShortcutsInterface,
      "Activated", kPortalObjectPath, nullptr, G_DBUS_SIGNAL_FLAGS_NONE,
      activated_cb, plugin, nullptr);
}

void start_bind_shortcuts(PendingInitialize* pending);

void bind_response_cb(GDBusConnection* connection,
                      const gchar* sender_name,
                      const gchar* object_path,
                      const gchar* interface_name,
                      const gchar* signal_name,
                      GVariant* parameters,
                      gpointer user_data) {
  auto* request = static_cast<PortalRequest*>(user_data);
  GlobalShortcutsPlugin* plugin = request->plugin;
  PendingInitialize* pending = request->pending;
  guint subscription_id = request->subscription_id;
  guint response = 0;
  GVariant* results = nullptr;
  g_variant_get(parameters, "(u@a{sv})", &response, &results);

  g_dbus_connection_signal_unsubscribe(plugin->connection, subscription_id);

  if (response == 0 &&
      response_has_all_shortcuts(results, pending->shortcuts)) {
    g_variant_unref(results);
    finish_initialize_success(pending);
    return;
  }

  g_variant_unref(results);
  if (response == 1) {
    finish_initialize_error(pending, "cancelled",
                            "Global shortcut binding was cancelled");
  } else if (response == 2) {
    finish_initialize_error(pending, "failed",
                            "Global shortcut binding did not complete");
  } else {
    finish_initialize_error(pending, "failed",
                            "Portal did not bind the requested shortcuts");
  }
}

void list_response_cb(GDBusConnection* connection,
                      const gchar* sender_name,
                      const gchar* object_path,
                      const gchar* interface_name,
                      const gchar* signal_name,
                      GVariant* parameters,
                      gpointer user_data) {
  auto* request = static_cast<PortalRequest*>(user_data);
  GlobalShortcutsPlugin* plugin = request->plugin;
  PendingInitialize* pending = request->pending;
  guint subscription_id = request->subscription_id;
  guint response = 0;
  GVariant* results = nullptr;
  g_variant_get(parameters, "(u@a{sv})", &response, &results);

  g_dbus_connection_signal_unsubscribe(plugin->connection, subscription_id);

  if (response == 0 && response_has_all_shortcuts(results, pending->shortcuts)) {
    g_variant_unref(results);
    finish_initialize_success(pending);
    return;
  }

  g_variant_unref(results);
  if (response == 0) {
    start_bind_shortcuts(pending);
  } else {
    finish_initialize_error(pending, "failed",
                            "Failed to list existing global shortcuts");
  }
}

void create_response_cb(GDBusConnection* connection,
                        const gchar* sender_name,
                        const gchar* object_path,
                        const gchar* interface_name,
                        const gchar* signal_name,
                        GVariant* parameters,
                        gpointer user_data) {
  auto* request = static_cast<PortalRequest*>(user_data);
  GlobalShortcutsPlugin* plugin = request->plugin;
  PendingInitialize* pending = request->pending;
  guint subscription_id = request->subscription_id;
  guint response = 0;
  GVariant* results = nullptr;
  g_variant_get(parameters, "(u@a{sv})", &response, &results);

  g_dbus_connection_signal_unsubscribe(plugin->connection, subscription_id);

  if (response != 0) {
    g_variant_unref(results);
    finish_initialize_error(pending, "failed",
                            "Failed to create a global shortcuts session");
    return;
  }

  const gchar* session_handle = nullptr;
  if (!g_variant_lookup(results, "session_handle", "&s", &session_handle)) {
    g_variant_unref(results);
    finish_initialize_error(pending, "failed",
                            "Portal did not return a shortcuts session");
    return;
  }

  g_free(pending->plugin->session_handle);
  pending->plugin->session_handle = g_strdup(session_handle);
  subscribe_activation(pending->plugin);
  g_variant_unref(results);

  g_autofree gchar* token = next_token(pending->plugin, "list");
  GVariantBuilder options;
  g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(&options, "{sv}", "handle_token",
                        g_variant_new_string(token));

  g_dbus_connection_call(
      pending->plugin->connection, kPortalBusName, kPortalObjectPath,
      kGlobalShortcutsInterface, "ListShortcuts",
      g_variant_new("(oa{sv})", pending->plugin->session_handle, &options),
      G_VARIANT_TYPE("(o)"), G_DBUS_CALL_FLAGS_NONE, -1,
      pending->plugin->cancellable,
      [](GObject* object, GAsyncResult* result, gpointer user_data) {
        auto* pending = static_cast<PendingInitialize*>(user_data);
        g_autoptr(GError) error = nullptr;
        g_autoptr(GVariant) reply = g_dbus_connection_call_finish(
            G_DBUS_CONNECTION(object), result, &error);
        if (reply == nullptr) {
          finish_initialize_error(pending, "failed", error->message);
          return;
        }

        const gchar* request_handle = nullptr;
        g_variant_get(reply, "(&o)", &request_handle);
        wait_for_request(pending->plugin, pending, RequestKind::kListShortcuts,
                         request_handle, list_response_cb);
      },
      pending);
}

void start_bind_shortcuts(PendingInitialize* pending) {
  g_autofree gchar* token = next_token(pending->plugin, "bind");
  GVariantBuilder options;
  g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(&options, "{sv}", "handle_token",
                        g_variant_new_string(token));

  GVariantBuilder shortcuts;
  g_variant_builder_init(&shortcuts, G_VARIANT_TYPE("a(sa{sv})"));
  for (const ShortcutSpec& shortcut : pending->shortcuts) {
    GVariantBuilder properties;
    g_variant_builder_init(&properties, G_VARIANT_TYPE_VARDICT);
    g_variant_builder_add(&properties, "{sv}", "description",
                          g_variant_new_string(shortcut.description.c_str()));
    g_variant_builder_add(
        &properties, "{sv}", "preferred_trigger",
        g_variant_new_string(shortcut.preferred_trigger.c_str()));
    g_variant_builder_add(&shortcuts, "(sa{sv})", shortcut.id.c_str(),
                          &properties);
  }

  g_dbus_connection_call(
      pending->plugin->connection, kPortalBusName, kPortalObjectPath,
      kGlobalShortcutsInterface, "BindShortcuts",
      g_variant_new("(oa(sa{sv})sa{sv})", pending->plugin->session_handle,
                    &shortcuts, "", &options),
      G_VARIANT_TYPE("(o)"), G_DBUS_CALL_FLAGS_NONE, -1,
      pending->plugin->cancellable,
      [](GObject* object, GAsyncResult* result, gpointer user_data) {
        auto* pending = static_cast<PendingInitialize*>(user_data);
        g_autoptr(GError) error = nullptr;
        g_autoptr(GVariant) reply = g_dbus_connection_call_finish(
            G_DBUS_CONNECTION(object), result, &error);
        if (reply == nullptr) {
          finish_initialize_error(pending, "failed", error->message);
          return;
        }

        const gchar* request_handle = nullptr;
        g_variant_get(reply, "(&o)", &request_handle);
        wait_for_request(pending->plugin, pending, RequestKind::kBindShortcuts,
                         request_handle, bind_response_cb);
      },
      pending);
}

void start_create_session(PendingInitialize* pending) {
  g_autofree gchar* handle_token = next_token(pending->plugin, "create");
  g_autofree gchar* session_token = next_token(pending->plugin, "session");

  GVariantBuilder options;
  g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(&options, "{sv}", "handle_token",
                        g_variant_new_string(handle_token));
  g_variant_builder_add(&options, "{sv}", "session_handle_token",
                        g_variant_new_string(session_token));

  g_dbus_connection_call(
      pending->plugin->connection, kPortalBusName, kPortalObjectPath,
      kGlobalShortcutsInterface, "CreateSession",
      g_variant_new("(a{sv})", &options), G_VARIANT_TYPE("(o)"),
      G_DBUS_CALL_FLAGS_NONE, -1, pending->plugin->cancellable,
      [](GObject* object, GAsyncResult* result, gpointer user_data) {
        auto* pending = static_cast<PendingInitialize*>(user_data);
        g_autoptr(GError) error = nullptr;
        g_autoptr(GVariant) reply = g_dbus_connection_call_finish(
            G_DBUS_CONNECTION(object), result, &error);
        if (reply == nullptr) {
          finish_initialize_error(pending, "failed", error->message);
          return;
        }

        const gchar* request_handle = nullptr;
        g_variant_get(reply, "(&o)", &request_handle);
        wait_for_request(pending->plugin, pending, RequestKind::kCreateSession,
                         request_handle, create_response_cb);
      },
      pending);
}

void handle_initialize(GlobalShortcutsPlugin* plugin,
                       FlMethodCall* method_call) {
  close_session(plugin);

  g_autoptr(GError) error = nullptr;
  if (!ensure_connection(plugin, &error)) {
    respond_error(method_call, "unavailable", error->message);
    return;
  }

  auto* pending = new PendingInitialize();
  pending->plugin = plugin;
  pending->method_call = FL_METHOD_CALL(g_object_ref(method_call));
  pending->shortcuts = parse_shortcuts(fl_method_call_get_args(method_call));
  start_create_session(pending);
}

void handle_dispose(GlobalShortcutsPlugin* plugin, FlMethodCall* method_call) {
  close_session(plugin);
  respond_success(method_call);
}

void method_call_cb(FlMethodChannel* channel,
                    FlMethodCall* method_call,
                    gpointer user_data) {
  auto* plugin = static_cast<GlobalShortcutsPlugin*>(user_data);
  const gchar* method = fl_method_call_get_name(method_call);

  if (std::strcmp(method, "initialize") == 0) {
    handle_initialize(plugin, method_call);
  } else if (std::strcmp(method, "dispose") == 0) {
    handle_dispose(plugin, method_call);
  } else {
    g_autoptr(GError) error = nullptr;
    if (!fl_method_call_respond_not_implemented(method_call, &error)) {
      g_warning("Failed to send not implemented response: %s", error->message);
    }
  }
}

FlMethodErrorResponse* listen_cb(FlEventChannel* channel,
                                 FlValue* args,
                                 gpointer user_data) {
  auto* plugin = static_cast<GlobalShortcutsPlugin*>(user_data);
  plugin->events_listening = TRUE;
  return nullptr;
}

FlMethodErrorResponse* cancel_cb(FlEventChannel* channel,
                                 FlValue* args,
                                 gpointer user_data) {
  auto* plugin = static_cast<GlobalShortcutsPlugin*>(user_data);
  plugin->events_listening = FALSE;
  return nullptr;
}

void destroy_plugin(gpointer data) {
  auto* plugin = static_cast<GlobalShortcutsPlugin*>(data);
  close_session(plugin);
  g_clear_object(&plugin->cancellable);
  g_clear_object(&plugin->connection);
  g_clear_object(&plugin->method_channel);
  g_clear_object(&plugin->event_channel);
  delete plugin;
}

}  // namespace

void sttapp_global_shortcuts_register(FlView* view) {
  auto* plugin = new GlobalShortcutsPlugin();
  plugin->cancellable = g_cancellable_new();

  FlBinaryMessenger* messenger =
      fl_engine_get_binary_messenger(fl_view_get_engine(view));

  g_autoptr(FlStandardMethodCodec) method_codec =
      fl_standard_method_codec_new();
  plugin->method_channel = fl_method_channel_new(
      messenger, kMethodChannelName, FL_METHOD_CODEC(method_codec));
  fl_method_channel_set_method_call_handler(plugin->method_channel,
                                            method_call_cb, plugin, nullptr);

  g_autoptr(FlStandardMethodCodec) event_codec =
      fl_standard_method_codec_new();
  plugin->event_channel = fl_event_channel_new(
      messenger, kEventChannelName, FL_METHOD_CODEC(event_codec));
  fl_event_channel_set_stream_handlers(plugin->event_channel, listen_cb,
                                       cancel_cb, plugin, nullptr);

  g_object_set_data_full(G_OBJECT(view), "sttapp-global-shortcuts", plugin,
                         destroy_plugin);
}

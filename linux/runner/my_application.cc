#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#include <string>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"
#include "sttapp_global_shortcuts.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

static std::string desktop_exec_quote(const gchar* value) {
  std::string quoted = "\"";
  for (const gchar* cursor = value; cursor != nullptr && *cursor != '\0';
       ++cursor) {
    switch (*cursor) {
      case '\\':
      case '"':
      case '`':
      case '$':
        quoted += '\\';
        quoted += *cursor;
        break;
      case '\n':
        break;
      default:
        quoted += *cursor;
    }
  }
  quoted += "\"";
  return quoted;
}

static bool is_executable_file(const gchar* path) {
  return path != nullptr && path[0] != '\0' &&
         g_file_test(path, static_cast<GFileTest>(G_FILE_TEST_IS_REGULAR |
                                                  G_FILE_TEST_IS_EXECUTABLE));
}

static gchar* get_desktop_exec_target(const gchar* executable_path) {
  const gchar* appimage_path = g_getenv("APPIMAGE");
  if (is_executable_file(appimage_path)) {
    return g_strdup(appimage_path);
  }

  const gchar* launcher_path = g_getenv("STTAPP_LAUNCHER_PATH");
  if (is_executable_file(launcher_path)) {
    return g_strdup(launcher_path);
  }

  g_autofree gchar* executable_basename = g_path_get_basename(executable_path);
  if (g_strcmp0(executable_basename, "sttapp.bin") == 0) {
    g_autofree gchar* executable_dirname = g_path_get_dirname(executable_path);
    g_autofree gchar* sibling_launcher =
        g_build_filename(executable_dirname, "sttapp", nullptr);
    if (is_executable_file(sibling_launcher)) {
      return g_strdup(sibling_launcher);
    }
  }

  return g_strdup(executable_path);
}

static void ensure_user_desktop_file() {
  g_autoptr(GError) error = nullptr;
  g_autofree gchar* executable_path = g_file_read_link("/proc/self/exe", &error);
  if (executable_path == nullptr) {
    g_warning("Failed to resolve executable path for desktop entry: %s",
              error->message);
    return;
  }

  g_autofree gchar* applications_dir =
      g_build_filename(g_get_user_data_dir(), "applications", nullptr);
  if (g_mkdir_with_parents(applications_dir, 0700) != 0) {
    g_warning("Failed to create user applications directory: %s",
              applications_dir);
    return;
  }

  g_autofree gchar* desktop_exec_target =
      get_desktop_exec_target(executable_path);
  const std::string exec = desktop_exec_quote(desktop_exec_target);
  g_autofree gchar* desktop_file_path =
      g_build_filename(applications_dir, APPLICATION_ID ".desktop", nullptr);
  g_autofree gchar* desktop_file_contents = g_strdup_printf(
      "[Desktop Entry]\n"
      "Type=Application\n"
      "Name=sttapp\n"
      "Comment=Speech-to-text capture and paste\n"
      "Exec=%s\n"
      "Icon=sttapp\n"
      "Terminal=false\n"
      "Categories=Utility;\n"
      "StartupWMClass=%s\n",
      exec.c_str(), APPLICATION_ID);

  g_autofree gchar* existing_desktop_file_contents = nullptr;
  g_autoptr(GError) read_error = nullptr;
  if (g_file_get_contents(desktop_file_path, &existing_desktop_file_contents,
                          nullptr, &read_error) &&
      g_strcmp0(existing_desktop_file_contents, desktop_file_contents) == 0) {
    return;
  }

  g_autoptr(GError) write_error = nullptr;
  if (!g_file_set_contents(desktop_file_path, desktop_file_contents, -1,
                           &write_error)) {
    g_warning("Failed to write desktop entry %s: %s", desktop_file_path,
              write_error->message);
  }
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "sttapp");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "sttapp");
  }

  gtk_window_set_default_size(window, 1280, 720);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));
  sttapp_global_shortcuts_register(view);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);
  g_set_application_name("sttapp");
  ensure_user_desktop_file();

  GApplicationFlags flags = static_cast<GApplicationFlags>(0);
#ifndef NDEBUG
  // Debug launches must be able to run beside an installed tray instance with
  // the same application ID, otherwise `flutter run` exits before VM service
  // startup and the tool reports that the log reader never started.
  flags = static_cast<GApplicationFlags>(flags | G_APPLICATION_NON_UNIQUE);
#endif

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     flags, nullptr));
}

#include "my_application.h"

#include <flutter_linux/flutter_linux.h>

#include <cstring>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "clipboard_plugin.h"
#include "flutter/generated_plugin_registrant.h"
#include "window_state.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// On Wayland (and in GNOME's dock on X11 too) the window icon set below is
// ignored: the shell shows the icon of the desktop entry whose name matches
// the app id. A portable bundle (unpacked tarball, `flutter run`) has none
// installed, so register one in ~/.local/share/applications pointing at this
// binary and its icon. Rewritten only when its content changes, e.g. after
// the bundle folder was moved.
static void register_desktop_entry(const gchar* bundle_dir, const gchar* exe) {
  // Characters that would need escaping in Exec=; such paths are skipped.
  if (strpbrk(exe, "\"`$\\\n") != nullptr ||
      strpbrk(bundle_dir, "\\\n") != nullptr) {
    return;
  }
  g_autofree gchar* icon =
      g_build_filename(bundle_dir, "data", "app_icon.png", nullptr);
  g_autofree gchar* content = g_strdup_printf(
      "[Desktop Entry]\n"
      "Type=Application\n"
      "Name=Loot Silo\n"
      "Comment=Your game assets. At a glance.\n"
      "Exec=\"%s\"\n"
      "Icon=%s\n"
      "Terminal=false\n"
      "Categories=Graphics;Development;\n"
      "StartupWMClass=%s\n",
      exe, icon, APPLICATION_ID);

  g_autofree gchar* apps_dir =
      g_build_filename(g_get_user_data_dir(), "applications", nullptr);
  g_autofree gchar* path =
      g_build_filename(apps_dir, APPLICATION_ID ".desktop", nullptr);
  g_autofree gchar* existing = nullptr;
  if (g_file_get_contents(path, &existing, nullptr, nullptr) &&
      g_strcmp0(existing, content) == 0) {
    return;
  }
  if (g_mkdir_with_parents(apps_dir, 0755) != 0) return;
  g_file_set_contents(path, content, -1, nullptr);
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);

  // The bundle folder: the binary sits next to data/ and lib/.
  g_autofree gchar* exe = g_file_read_link("/proc/self/exe", nullptr);
  g_autofree gchar* bundle_dir =
      exe != nullptr ? g_path_get_dirname(exe) : nullptr;
  if (exe != nullptr) register_desktop_entry(bundle_dir, exe);

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
    gtk_header_bar_set_title(header_bar, "Loot Silo");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "Loot Silo");
  }

  // Last run's size, position and maximized state, fitted to the monitors
  // present now; 1280x720 the first time.
  window_state_attach(window, 1280, 720);

  // The window / taskbar icon, installed next to the binary
  // (bundle/data/app_icon.png). Used by X11 window managers other than GNOME.
  if (bundle_dir != nullptr) {
    g_autofree gchar* icon =
        g_build_filename(bundle_dir, "data", "app_icon.png", nullptr);
    gtk_window_set_icon_from_file(window, icon, nullptr);
  }

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

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));
  {
    // Our own channel: images and files on the clipboard, Open with.
    g_autoptr(FlPluginRegistrar) clipboard =
        fl_plugin_registry_get_registrar_for_plugin(FL_PLUGIN_REGISTRY(view),
                                                    "LootSiloClipboard");
    clipboard_plugin_register_with_registrar(clipboard);
  }

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

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}

#include "clipboard_plugin.h"

#include <gio/gio.h>
#include <gtk/gtk.h>

#include <cstring>

namespace {

// What copyFiles offers until something else takes the clipboard.
struct FileData {
  gchar** uris;        // file:// URIs
  gchar* text;         // the paths, one per line
  gchar* extra_mime;   // e.g. "image/gif", or null
  GBytes* extra_bytes;
};

enum Target {
  kUriList,
  kGnomeCopied,
  kText,
  kExtra,
};

void free_file_data(FileData* data) {
  g_strfreev(data->uris);
  g_free(data->text);
  g_free(data->extra_mime);
  if (data->extra_bytes != nullptr) g_bytes_unref(data->extra_bytes);
  g_free(data);
}

void get_files(GtkClipboard* clipboard, GtkSelectionData* selection,
               guint info, gpointer user_data) {
  auto* data = static_cast<FileData*>(user_data);
  switch (info) {
    case kUriList:
      gtk_selection_data_set_uris(selection, data->uris);
      break;
    case kGnomeCopied: {
      // "copy\nfile:///a\nfile:///b" (Nautilus, Thunar, Dolphin, Caja).
      g_autoptr(GString) s = g_string_new("copy");
      for (gchar** u = data->uris; *u != nullptr; u++) {
        g_string_append_c(s, '\n');
        g_string_append(s, *u);
      }
      gtk_selection_data_set(selection, gtk_selection_data_get_target(selection),
                             8, reinterpret_cast<const guchar*>(s->str),
                             s->len);
      break;
    }
    case kText:
      gtk_selection_data_set_text(selection, data->text, -1);
      break;
    case kExtra: {
      gsize size = 0;
      const guchar* bytes = static_cast<const guchar*>(
          g_bytes_get_data(data->extra_bytes, &size));
      gtk_selection_data_set(selection, gtk_selection_data_get_target(selection),
                             8, bytes, size);
      break;
    }
  }
}

void clear_files(GtkClipboard* clipboard, gpointer user_data) {
  free_file_data(static_cast<FileData*>(user_data));
}

GtkClipboard* clipboard() {
  return gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
}

FlMethodResponse* error(const gchar* code, const gchar* message) {
  return FL_METHOD_RESPONSE(fl_method_error_response_new(code, message, nullptr));
}

FlMethodResponse* ok(FlValue* value = nullptr) {
  return FL_METHOD_RESPONSE(fl_method_success_response_new(value));
}

FlMethodResponse* copy_image(FlValue* args) {
  if (fl_value_get_type(args) != FL_VALUE_TYPE_UINT8_LIST) {
    return error("bad-args", "copyImage takes PNG bytes");
  }
  g_autoptr(GdkPixbufLoader) loader = gdk_pixbuf_loader_new_with_type("png", nullptr);
  g_autoptr(GError) err = nullptr;
  if (loader == nullptr ||
      !gdk_pixbuf_loader_write(loader, fl_value_get_uint8_list(args),
                               fl_value_get_length(args), &err) ||
      !gdk_pixbuf_loader_close(loader, &err)) {
    return error("decode", err != nullptr ? err->message : "not a PNG");
  }
  GdkPixbuf* pixbuf = gdk_pixbuf_loader_get_pixbuf(loader);
  if (pixbuf == nullptr) return error("decode", "no image");
  // Offers image/png, image/bmp, image/jpeg … made from the pixbuf on
  // request, at its own size.
  gtk_clipboard_set_image(clipboard(), pixbuf);
  gtk_clipboard_store(clipboard());
  return ok();
}

FlMethodResponse* copy_files(FlValue* args) {
  if (fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return error("bad-args", "copyFiles takes a map");
  }
  FlValue* paths = fl_value_lookup_string(args, "paths");
  if (paths == nullptr || fl_value_get_type(paths) != FL_VALUE_TYPE_LIST ||
      fl_value_get_length(paths) == 0) {
    return error("bad-args", "no paths");
  }
  const size_t n = fl_value_get_length(paths);
  auto* data = g_new0(FileData, 1);
  data->uris = g_new0(gchar*, n + 1);
  g_autoptr(GString) text = g_string_new(nullptr);
  for (size_t i = 0; i < n; i++) {
    const gchar* path = fl_value_get_string(fl_value_get_list_value(paths, i));
    data->uris[i] = g_filename_to_uri(path, nullptr, nullptr);
    if (data->uris[i] == nullptr) data->uris[i] = g_strdup("");
    if (i > 0) g_string_append_c(text, '\n');
    g_string_append(text, path);
  }
  data->text = g_strdup(text->str);

  g_autoptr(GtkTargetList) list = gtk_target_list_new(nullptr, 0);
  FlValue* mime = fl_value_lookup_string(args, "mime");
  FlValue* bytes = fl_value_lookup_string(args, "bytes");
  if (mime != nullptr && bytes != nullptr &&
      fl_value_get_type(mime) == FL_VALUE_TYPE_STRING &&
      fl_value_get_type(bytes) == FL_VALUE_TYPE_UINT8_LIST) {
    data->extra_mime = g_strdup(fl_value_get_string(mime));
    data->extra_bytes = g_bytes_new(fl_value_get_uint8_list(bytes),
                                    fl_value_get_length(bytes));
    gtk_target_list_add(list, gdk_atom_intern(data->extra_mime, FALSE), 0,
                        kExtra);
  }
  gtk_target_list_add(list, gdk_atom_intern_static_string("x-special/gnome-copied-files"), 0,
                      kGnomeCopied);
  gtk_target_list_add_uri_targets(list, kUriList);
  gtk_target_list_add_text_targets(list, kText);
  gint count = 0;
  GtkTargetEntry* targets = gtk_target_table_new_from_list(list, &count);
  const gboolean set = gtk_clipboard_set_with_data(
      clipboard(), targets, count, get_files, clear_files, data);
  gtk_target_table_free(targets, count);
  if (!set) {
    free_file_data(data);
    return error("clipboard", "the clipboard refused the files");
  }
  gtk_clipboard_store(clipboard());
  return ok();
}

FlMethodResponse* read(FlValue* args) {
  if (fl_value_get_type(args) != FL_VALUE_TYPE_STRING) {
    return error("bad-args", "read takes a target name");
  }
  GtkSelectionData* selection = gtk_clipboard_wait_for_contents(
      clipboard(), gdk_atom_intern(fl_value_get_string(args), FALSE));
  if (selection == nullptr) return ok(fl_value_new_null());
  gint length = 0;
  const guchar* bytes = gtk_selection_data_get_data_with_length(selection, &length);
  g_autoptr(FlValue) value =
      length < 0 ? fl_value_new_null() : fl_value_new_uint8_list(bytes, length);
  gtk_selection_data_free(selection);
  return ok(fl_value_ref(value));
}

FlMethodResponse* open_with(FlValue* args, GtkWindow* window) {
  if (fl_value_get_type(args) != FL_VALUE_TYPE_STRING) {
    return error("bad-args", "openWith takes a path");
  }
  g_autoptr(GFile) file = g_file_new_for_path(fl_value_get_string(args));
  GtkWidget* dialog = gtk_app_chooser_dialog_new(
      window, GTK_DIALOG_MODAL, file);
  gtk_app_chooser_dialog_set_heading(GTK_APP_CHOOSER_DIALOG(dialog),
                                     "Open with");
  const gint response = gtk_dialog_run(GTK_DIALOG(dialog));
  g_autoptr(GAppInfo) app = nullptr;
  if (response == GTK_RESPONSE_OK) {
    app = gtk_app_chooser_get_app_info(GTK_APP_CHOOSER(dialog));
  }
  gtk_widget_destroy(dialog);
  if (app == nullptr) return ok(fl_value_new_bool(FALSE));
  GList* files = g_list_append(nullptr, file);
  g_autoptr(GError) err = nullptr;
  const gboolean launched = g_app_info_launch(app, files, nullptr, &err);
  g_list_free(files);
  if (!launched) {
    return error("launch", err != nullptr ? err->message : "could not start");
  }
  return ok(fl_value_new_bool(TRUE));
}

void method_call_cb(FlMethodChannel* channel, FlMethodCall* call,
                    gpointer user_data) {
  auto* registrar = FL_PLUGIN_REGISTRAR(user_data);
  const gchar* method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  g_autoptr(FlMethodResponse) response = nullptr;
  if (strcmp(method, "copyImage") == 0) {
    response = copy_image(args);
  } else if (strcmp(method, "copyFiles") == 0) {
    response = copy_files(args);
  } else if (strcmp(method, "read") == 0) {
    response = read(args);
  } else if (strcmp(method, "openWith") == 0) {
    FlView* view = fl_plugin_registrar_get_view(registrar);
    GtkWidget* top = view == nullptr ? nullptr
                                     : gtk_widget_get_toplevel(GTK_WIDGET(view));
    response = open_with(args, GTK_IS_WINDOW(top) ? GTK_WINDOW(top) : nullptr);
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(call, response, nullptr);
}

}  // namespace

void clipboard_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  // Kept for the app's lifetime.
  FlMethodChannel* channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar), "loot_silo/clipboard",
      FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      channel, method_call_cb, g_object_ref(registrar), g_object_unref);
}

#include "window_state.h"

#include <algorithm>
#include <vector>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

namespace {

constexpr char kGroup[] = "window";
// Smaller saved sizes are treated as broken.
constexpr int kMinWidth = 480;
constexpr int kMinHeight = 320;
// The strip at the top of the window that holds the title bar: at least
// kMinGrab pixels of it must be on some monitor for the window to be
// reachable, or it is moved.
constexpr int kTitleBarHeight = 40;
constexpr int kMinGrab = 100;

struct Rect {
  int x = 0, y = 0, w = 0, h = 0;
};

Rect intersect(const Rect& a, const Rect& b) {
  const int x1 = std::max(a.x, b.x);
  const int y1 = std::max(a.y, b.y);
  const int x2 = std::min(a.x + a.w, b.x + b.w);
  const int y2 = std::min(a.y + a.h, b.y + b.h);
  if (x2 <= x1 || y2 <= y1) return Rect{};
  return Rect{x1, y1, x2 - x1, y2 - y1};
}

// What is remembered. Width and height are the normal (not maximized) size,
// in GTK's logical pixels, as gtk_window_get_size gives them.
struct State {
  int x = 0, y = 0, width = 0, height = 0;
  bool has_position = false;
  bool maximized = false;
};

// Lives as long as the window; written to disk when the window goes away.
struct Tracker {
  State state;
  bool can_position = false;  // X11: the app may read and set its position.
};

gchar* state_path() {
  return g_build_filename(g_get_user_data_dir(), APPLICATION_ID,
                          "window_state.ini", nullptr);
}

bool load(State* out) {
  g_autofree gchar* path = state_path();
  g_autoptr(GKeyFile) file = g_key_file_new();
  if (!g_key_file_load_from_file(file, path, G_KEY_FILE_NONE, nullptr)) {
    return false;
  }
  g_autoptr(GError) error = nullptr;
  out->width = g_key_file_get_integer(file, kGroup, "width", &error);
  if (error != nullptr) return false;
  out->height = g_key_file_get_integer(file, kGroup, "height", &error);
  if (error != nullptr) return false;
  out->maximized = g_key_file_get_boolean(file, kGroup, "maximized", nullptr);
  const int x = g_key_file_get_integer(file, kGroup, "x", &error);
  if (error == nullptr) {
    const int y = g_key_file_get_integer(file, kGroup, "y", &error);
    if (error == nullptr) {
      out->x = x;
      out->y = y;
      out->has_position = true;
    }
  }
  return out->width >= kMinWidth && out->height >= kMinHeight;
}

void save(const State& state) {
  if (state.width <= 0 || state.height <= 0) return;
  g_autoptr(GKeyFile) file = g_key_file_new();
  g_key_file_set_integer(file, kGroup, "width", state.width);
  g_key_file_set_integer(file, kGroup, "height", state.height);
  g_key_file_set_boolean(file, kGroup, "maximized", state.maximized);
  if (state.has_position) {
    g_key_file_set_integer(file, kGroup, "x", state.x);
    g_key_file_set_integer(file, kGroup, "y", state.y);
  }
  g_autofree gchar* path = state_path();
  g_autofree gchar* dir = g_path_get_dirname(path);
  if (g_mkdir_with_parents(dir, 0755) != 0) return;
  g_key_file_save_to_file(file, path, nullptr);
}

// The usable area (screen minus panels and docks) of every monitor, primary
// first. Empty when GDK reports none.
std::vector<Rect> work_areas() {
  std::vector<Rect> areas;
  GdkDisplay* display = gdk_display_get_default();
  if (display == nullptr) return areas;
  GdkMonitor* primary = gdk_display_get_primary_monitor(display);
  const int n = gdk_display_get_n_monitors(display);
  for (int i = 0; i < n; i++) {
    GdkMonitor* monitor = gdk_display_get_monitor(display, i);
    GdkRectangle wa;
    gdk_monitor_get_workarea(monitor, &wa);
    const Rect r{wa.x, wa.y, wa.width, wa.height};
    if (monitor == primary) {
      areas.insert(areas.begin(), r);
    } else {
      areas.push_back(r);
    }
  }
  return areas;
}

// Fits the saved place to the monitors present now. Keeps the position when
// the title bar is reachable on some monitor (shifting the window fully onto
// the monitor it overlaps most), otherwise centres it on the primary one.
// Shrinks the size to the chosen monitor's work area.
State fit(State state, const std::vector<Rect>& areas, bool can_position) {
  if (!can_position) state.has_position = false;
  if (areas.empty()) return state;

  Rect target = areas[0];
  bool reachable = false;
  if (state.has_position) {
    const Rect window{state.x, state.y, state.width, state.height};
    const Rect title{state.x, state.y, state.width, kTitleBarHeight};
    long best_overlap = 0;
    for (const Rect& area : areas) {
      if (intersect(title, area).w >= std::min(kMinGrab, state.width)) {
        reachable = true;
      }
      const Rect overlap = intersect(window, area);
      const long size = static_cast<long>(overlap.w) * overlap.h;
      if (size > best_overlap) {
        best_overlap = size;
        target = area;
      }
    }
    if (!reachable) target = areas[0];
  }

  state.width = std::min(state.width, target.w);
  state.height = std::min(state.height, target.h);
  if (reachable) {
    state.x = std::clamp(state.x, target.x, target.x + target.w - state.width);
    state.y =
        std::clamp(state.y, target.y, target.y + target.h - state.height);
  } else if (can_position) {
    state.x = target.x + (target.w - state.width) / 2;
    state.y = target.y + (target.h - state.height) / 2;
    state.has_position = true;
  }
  return state;
}

gboolean on_configure(GtkWidget* widget, GdkEventConfigure*, gpointer data) {
  auto* tracker = static_cast<Tracker*>(data);
  GdkWindow* gdk_window = gtk_widget_get_window(widget);
  const GdkWindowState flags =
      gdk_window != nullptr ? gdk_window_get_state(gdk_window)
                            : static_cast<GdkWindowState>(0);
  // Maximized, fullscreen or snapped to half the screen: keep the normal
  // size and place from before, for when the window goes back to normal.
  if (flags & (GDK_WINDOW_STATE_MAXIMIZED | GDK_WINDOW_STATE_FULLSCREEN |
               GDK_WINDOW_STATE_TILED)) {
    return FALSE;
  }
  GtkWindow* window = GTK_WINDOW(widget);
  gtk_window_get_size(window, &tracker->state.width, &tracker->state.height);
  if (tracker->can_position) {
    gtk_window_get_position(window, &tracker->state.x, &tracker->state.y);
    tracker->state.has_position = true;
  }
  return FALSE;
}

gboolean on_window_state(GtkWidget*, GdkEventWindowState* event,
                         gpointer data) {
  auto* tracker = static_cast<Tracker*>(data);
  tracker->state.maximized =
      (event->new_window_state & GDK_WINDOW_STATE_MAXIMIZED) != 0;
  return FALSE;
}

// The close button / Alt+F4. Flutter's engine handles the close request and
// ends the process without destroying the window, so save here. Connected
// before Flutter's own handler, and never stops the close.
gboolean on_delete(GtkWidget*, GdkEvent*, gpointer data) {
  save(static_cast<Tracker*>(data)->state);
  return FALSE;
}

// Any other way the window goes away cleanly.
void on_destroy(GtkWidget*, gpointer data) {
  save(static_cast<Tracker*>(data)->state);
}

}  // namespace

void window_state_attach(GtkWindow* window, gint default_width,
                         gint default_height) {
  auto* tracker = new Tracker();
#ifdef GDK_WINDOWING_X11
  tracker->can_position = GDK_IS_X11_DISPLAY(gdk_display_get_default());
#endif

  State saved;
  if (load(&saved)) {
    const State placed = fit(saved, work_areas(), tracker->can_position);
    gtk_window_set_default_size(window, placed.width, placed.height);
    if (placed.has_position) gtk_window_move(window, placed.x, placed.y);
    if (placed.maximized) gtk_window_maximize(window);
    tracker->state = placed;
  } else {
    gtk_window_set_default_size(window, default_width, default_height);
    tracker->state.width = default_width;
    tracker->state.height = default_height;
  }

  g_signal_connect(window, "configure-event", G_CALLBACK(on_configure),
                   tracker);
  g_signal_connect(window, "window-state-event", G_CALLBACK(on_window_state),
                   tracker);
  g_signal_connect(window, "delete-event", G_CALLBACK(on_delete), tracker);
  g_signal_connect(window, "destroy", G_CALLBACK(on_destroy), tracker);
  g_object_set_data_full(G_OBJECT(window), "loot-silo-window-state", tracker,
                         [](gpointer p) { delete static_cast<Tracker*>(p); });
}

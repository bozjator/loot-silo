#ifndef RUNNER_WINDOW_STATE_H_
#define RUNNER_WINDOW_STATE_H_

#include <gtk/gtk.h>

// Remembers the main window's size, position and maximized state between
// runs, in window_state.ini next to settings.json
// (~/.local/share/<app id>/).
//
// The saved place is checked against the monitors present now: a window
// whose title bar would be off every screen (monitor unplugged, layout
// changed) goes centred onto the primary monitor, and one bigger than its
// monitor's work area is shrunk to fit.
//
// On Wayland the app can neither read nor set its own position, so only the
// size and maximized state come back there; the compositor places it.

// Applies the saved state to |window| (before it is shown) and starts
// tracking its changes. Writes the file when the window is closed.
void window_state_attach(GtkWindow* window, gint default_width,
                         gint default_height);

#endif  // RUNNER_WINDOW_STATE_H_

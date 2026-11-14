#ifndef RUNNER_WINDOW_STATE_H_
#define RUNNER_WINDOW_STATE_H_

#include <windows.h>

#include <optional>

// Remembers the main window's size, position and maximized state between
// runs, in %LOCALAPPDATA%\Bozjatorium\Loot Silo\window_state.ini (local,
// not roaming: the place only makes sense on this machine's monitors).
//
// The saved place is checked against the monitors present now: a window
// whose title bar would be off every screen (monitor unplugged, layout
// changed) goes centred onto the primary monitor, one saved at another
// display scale is resized to match, and one bigger than its monitor's work
// area is shrunk to fit.
struct WindowState {
  // The normal (not maximized) frame, in physical screen pixels.
  RECT frame;
  bool maximized;
};

// The saved state fitted to the current monitors, or nothing on first run or
// when the file is unreadable.
std::optional<WindowState> LoadWindowState();

// Writes |window|'s current state. Call while the window still exists.
void SaveWindowState(HWND window);

#endif  // RUNNER_WINDOW_STATE_H_

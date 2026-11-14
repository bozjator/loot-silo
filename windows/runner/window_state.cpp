#include "window_state.h"

#include <flutter_windows.h>
#include <shlobj.h>

#include <algorithm>
#include <cwchar>
#include <string>
#include <vector>

namespace {

constexpr wchar_t kSection[] = L"window";
// Smaller saved sizes (physical pixels) are treated as broken.
constexpr int kMinWidth = 320;
constexpr int kMinHeight = 240;
// The strip at the top of the window that holds the title bar: at least
// kMinGrab pixels of it must be on some monitor for the window to be
// reachable, or it is moved. Logical pixels, scaled by the monitor's DPI.
constexpr int kTitleBarHeight = 32;
constexpr int kMinGrab = 100;

int Width(const RECT& r) { return r.right - r.left; }
int Height(const RECT& r) { return r.bottom - r.top; }

// The folder path_provider calls the app's cache folder; Runner.rc names it
// (CompanyName, ProductName).
std::wstring StatePath() {
  PWSTR local = nullptr;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &local))) {
    return L"";
  }
  std::wstring dir = std::wstring(local) + L"\\Bozjatorium\\Loot Silo";
  CoTaskMemFree(local);
  SHCreateDirectoryExW(nullptr, dir.c_str(), nullptr);
  return dir + L"\\window_state.ini";
}

bool ReadInt(const std::wstring& path, const wchar_t* key, int* out) {
  wchar_t buffer[32];
  GetPrivateProfileStringW(kSection, key, L"", buffer, 32, path.c_str());
  if (buffer[0] == L'\0') return false;
  wchar_t* end = nullptr;
  const long value = std::wcstol(buffer, &end, 10);
  if (end == buffer || *end != L'\0') return false;
  *out = static_cast<int>(value);
  return true;
}

void WriteInt(const std::wstring& path, const wchar_t* key, int value) {
  WritePrivateProfileStringW(kSection, key, std::to_wstring(value).c_str(),
                             path.c_str());
}

struct Monitor {
  HMONITOR handle;
  RECT work;  // Screen minus the taskbar and docked bars.
};

BOOL CALLBACK CollectMonitor(HMONITOR handle, HDC, LPRECT, LPARAM data) {
  MONITORINFO info{sizeof(info)};
  if (GetMonitorInfoW(handle, &info)) {
    auto* monitors = reinterpret_cast<std::vector<Monitor>*>(data);
    const Monitor monitor{handle, info.rcWork};
    if (info.dwFlags & MONITORINFOF_PRIMARY) {
      monitors->insert(monitors->begin(), monitor);
    } else {
      monitors->push_back(monitor);
    }
  }
  return TRUE;
}

// Every monitor, primary first.
std::vector<Monitor> Monitors() {
  std::vector<Monitor> monitors;
  EnumDisplayMonitors(nullptr, nullptr, CollectMonitor,
                      reinterpret_cast<LPARAM>(&monitors));
  return monitors;
}

int Scale(int value, UINT dpi) { return MulDiv(value, dpi, 96); }

// Converts GetWindowPlacement's workspace coordinates (relative to the
// primary monitor's work area) to screen coordinates, and back.
POINT WorkspaceOffset() {
  MONITORINFO info{sizeof(info)};
  HMONITOR primary = MonitorFromPoint(POINT{0, 0}, MONITOR_DEFAULTTOPRIMARY);
  if (!GetMonitorInfoW(primary, &info)) return POINT{0, 0};
  return POINT{info.rcWork.left - info.rcMonitor.left,
               info.rcWork.top - info.rcMonitor.top};
}

}  // namespace

std::optional<WindowState> LoadWindowState() {
  const std::wstring path = StatePath();
  if (path.empty()) return std::nullopt;
  int x, y, width, height, dpi, maximized;
  if (!ReadInt(path, L"x", &x) || !ReadInt(path, L"y", &y) ||
      !ReadInt(path, L"width", &width) || !ReadInt(path, L"height", &height) ||
      !ReadInt(path, L"dpi", &dpi)) {
    return std::nullopt;
  }
  if (!ReadInt(path, L"maximized", &maximized)) maximized = 0;
  if (width < kMinWidth || height < kMinHeight || dpi < 48 || dpi > 960) {
    return std::nullopt;
  }

  const std::vector<Monitor> monitors = Monitors();
  if (monitors.empty()) return std::nullopt;

  // The monitor the window overlaps most, and whether its title bar can be
  // reached on any monitor.
  const RECT saved{x, y, x + width, y + height};
  const RECT title{x, y, x + width, y + kTitleBarHeight * dpi / 96};
  const Monitor* target = &monitors[0];
  long best_overlap = 0;
  bool reachable = false;
  for (const Monitor& monitor : monitors) {
    RECT overlap;
    if (IntersectRect(&overlap, &title, &monitor.work) &&
        Width(overlap) >= std::min(Scale(kMinGrab, dpi), width)) {
      reachable = true;
    }
    if (IntersectRect(&overlap, &saved, &monitor.work)) {
      const long size = static_cast<long>(Width(overlap)) * Height(overlap);
      if (size > best_overlap) {
        best_overlap = size;
        target = &monitor;
      }
    }
  }
  if (!reachable) target = &monitors[0];

  // Saved at another display scale (other monitor, or the scale setting
  // changed): keep the same size in logical pixels.
  const UINT target_dpi = FlutterDesktopGetDpiForMonitor(target->handle);
  if (target_dpi != static_cast<UINT>(dpi)) {
    width = MulDiv(width, target_dpi, dpi);
    height = MulDiv(height, target_dpi, dpi);
  }
  const RECT& work = target->work;
  width = std::min(width, Width(work));
  height = std::min(height, Height(work));
  if (reachable) {
    x = std::clamp(x, static_cast<int>(work.left),
                   static_cast<int>(work.right) - width);
    y = std::clamp(y, static_cast<int>(work.top),
                   static_cast<int>(work.bottom) - height);
  } else {
    x = work.left + (Width(work) - width) / 2;
    y = work.top + (Height(work) - height) / 2;
  }
  return WindowState{RECT{x, y, x + width, y + height}, maximized != 0};
}

void SaveWindowState(HWND window) {
  WINDOWPLACEMENT placement{sizeof(placement)};
  if (!GetWindowPlacement(window, &placement)) return;
  const std::wstring path = StatePath();
  if (path.empty()) return;

  // rcNormalPosition is the normal frame even while maximized, minimized or
  // snapped to half the screen.
  const POINT offset = WorkspaceOffset();
  RECT frame = placement.rcNormalPosition;
  OffsetRect(&frame, offset.x, offset.y);
  const bool maximized =
      placement.showCmd == SW_SHOWMAXIMIZED ||
      (placement.showCmd == SW_SHOWMINIMIZED &&
       (placement.flags & WPF_RESTORETOMAXIMIZED));
  const UINT dpi = FlutterDesktopGetDpiForMonitor(
      MonitorFromRect(&frame, MONITOR_DEFAULTTONEAREST));

  WriteInt(path, L"x", frame.left);
  WriteInt(path, L"y", frame.top);
  WriteInt(path, L"width", Width(frame));
  WriteInt(path, L"height", Height(frame));
  WriteInt(path, L"dpi", static_cast<int>(dpi));
  WriteInt(path, L"maximized", maximized ? 1 : 0);
}

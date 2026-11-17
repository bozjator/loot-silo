#include "clipboard_plugin.h"

#include <flutter/standard_method_codec.h>
#include <shellapi.h>
#include <shlobj.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <algorithm>
#include <cstring>
#include <optional>
#include <string>
#include <vector>

#include "utils.h"

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using Microsoft::WRL::ComPtr;
using Result = std::unique_ptr<flutter::MethodResult<EncodableValue>>;
using Bytes = std::vector<uint8_t>;

std::wstring Utf16FromUtf8(const std::string& s) {
  if (s.empty()) return std::wstring();
  const int n = ::MultiByteToWideChar(CP_UTF8, 0, s.data(),
                                      static_cast<int>(s.size()), nullptr, 0);
  std::wstring out(n, L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()),
                        out.data(), n);
  return out;
}

UINT PngFormat() {
  static const UINT format = ::RegisterClipboardFormatW(L"PNG");
  return format;
}

UINT DropEffectFormat() {
  static const UINT format =
      ::RegisterClipboardFormatW(CFSTR_PREFERREDDROPEFFECT);
  return format;
}

// The clipboard format for a MIME name: the name Windows apps use for
// PNG, the standard formats for text and bitmaps, else a format
// registered under the MIME name itself.
UINT FormatForMime(const std::string& mime) {
  if (mime == "image/png") return PngFormat();
  if (mime == "image/bmp") return CF_DIB;
  if (mime == "text/plain") return CF_UNICODETEXT;
  if (mime == "text/uri-list") return CF_HDROP;
  return ::RegisterClipboardFormatW(Utf16FromUtf8(mime).c_str());
}

// The MIME name for a format on offer, the inverse of FormatForMime;
// formats with no MIME name keep their Windows name.
std::string MimeForFormat(UINT format) {
  if (format == PngFormat()) return "image/png";
  switch (format) {
    case CF_DIB:
    case CF_DIBV5:
    case CF_BITMAP:
      return "image/bmp";
    case CF_UNICODETEXT:
    case CF_TEXT:
    case CF_OEMTEXT:
      return "text/plain";
    case CF_HDROP:
      return "text/uri-list";
    case CF_LOCALE:
      return "CF_LOCALE";
  }
  wchar_t name[256];
  const int n = ::GetClipboardFormatNameW(format, name, 256);
  if (n > 0) return Utf8FromUtf16(name);
  return "CF_" + std::to_string(format);
}

// A file URI the way Dart's Uri.file writes one for a Windows path, so the
// tests can compare them: file:///D:/a%20b/c.png, file://host/share/x.
std::string FileUri(const std::wstring& path) {
  std::string utf8 = Utf8FromUtf16(path.c_str());
  std::replace(utf8.begin(), utf8.end(), '\\', '/');
  std::string out = "file://";
  size_t start = 0;
  if (utf8.rfind("//", 0) == 0) {
    // UNC: the server is the host.
    const size_t slash = utf8.find('/', 2);
    out += utf8.substr(2, slash == std::string::npos ? std::string::npos
                                                     : slash - 2);
    start = slash == std::string::npos ? utf8.size() : slash;
  } else {
    out += '/';
  }
  static const char kHex[] = "0123456789ABCDEF";
  for (size_t i = start; i < utf8.size(); i++) {
    const unsigned char c = static_cast<unsigned char>(utf8[i]);
    if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
        (c >= '0' && c <= '9') || std::strchr("-._~!$&'()*+,;=:@/", c)) {
      out += static_cast<char>(c);
    } else {
      out += '%';
      out += kHex[c >> 4];
      out += kHex[c & 0xF];
    }
  }
  return out;
}

// GlobalAlloc'd copy of |size| bytes, for SetClipboardData.
HGLOBAL GlobalCopy(const void* data, size_t size) {
  HGLOBAL handle = ::GlobalAlloc(GMEM_MOVEABLE, size);
  if (handle == nullptr) return nullptr;
  void* dest = ::GlobalLock(handle);
  if (dest == nullptr) {
    ::GlobalFree(handle);
    return nullptr;
  }
  std::memcpy(dest, data, size);
  ::GlobalUnlock(handle);
  return handle;
}

// Opens the clipboard, retrying while another app has it open.
class OpenClipboard {
 public:
  explicit OpenClipboard(HWND owner) {
    for (int i = 0; i < 10 && !open_; i++) {
      open_ = ::OpenClipboard(owner) != 0;
      if (!open_) ::Sleep(20);
    }
  }
  ~OpenClipboard() {
    if (open_) ::CloseClipboard();
  }
  bool ok() const { return open_; }

 private:
  bool open_ = false;
};

// A format and the data for it, to put on the clipboard together.
struct Entry {
  UINT format;
  Bytes data;
};

// Replaces the clipboard's contents with |entries|; on failure, says which
// step failed and the Windows error.
std::optional<std::string> SetClipboard(HWND owner,
                                        const std::vector<Entry>& entries) {
  auto failed = [](const char* step) {
    return std::string(step) + " failed (error " +
           std::to_string(::GetLastError()) + ")";
  };
  OpenClipboard clipboard(owner);
  if (!clipboard.ok()) return failed("OpenClipboard");
  if (!::EmptyClipboard()) return failed("EmptyClipboard");
  for (const Entry& entry : entries) {
    HGLOBAL handle = GlobalCopy(entry.data.data(), entry.data.size());
    if (handle == nullptr) return failed("GlobalAlloc");
    // On success the clipboard owns the memory.
    if (::SetClipboardData(entry.format, handle) == nullptr) {
      const std::string message = failed("SetClipboardData");
      ::GlobalFree(handle);
      return message;
    }
  }
  return std::nullopt;
}

// The PNG decoded to a bottom-up 32-bit CF_DIBV5 with straight alpha, at
// its own size; Windows makes CF_DIB and CF_BITMAP from it for older apps.
std::optional<Bytes> DibFromPng(const Bytes& png) {
  ComPtr<IWICImagingFactory> factory;
  if (FAILED(::CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                CLSCTX_INPROC_SERVER,
                                IID_PPV_ARGS(&factory)))) {
    return std::nullopt;
  }
  ComPtr<IWICStream> stream;
  ComPtr<IWICBitmapDecoder> decoder;
  ComPtr<IWICBitmapFrameDecode> frame;
  ComPtr<IWICFormatConverter> converter;
  if (FAILED(factory->CreateStream(&stream)) ||
      FAILED(stream->InitializeFromMemory(const_cast<BYTE*>(png.data()),
                                          static_cast<DWORD>(png.size()))) ||
      FAILED(factory->CreateDecoderFromStream(
          stream.Get(), nullptr, WICDecodeMetadataCacheOnDemand, &decoder)) ||
      FAILED(decoder->GetFrame(0, &frame)) ||
      FAILED(factory->CreateFormatConverter(&converter)) ||
      FAILED(converter->Initialize(frame.Get(), GUID_WICPixelFormat32bppBGRA,
                                   WICBitmapDitherTypeNone, nullptr, 0.0,
                                   WICBitmapPaletteTypeCustom))) {
    return std::nullopt;
  }
  UINT width = 0, height = 0;
  if (FAILED(converter->GetSize(&width, &height)) || width == 0 ||
      height == 0) {
    return std::nullopt;
  }
  const UINT stride = width * 4;
  const size_t pixels = static_cast<size_t>(stride) * height;
  Bytes top_down(pixels);
  if (FAILED(converter->CopyPixels(nullptr, stride,
                                   static_cast<UINT>(pixels),
                                   top_down.data()))) {
    return std::nullopt;
  }

  BITMAPV5HEADER header = {};
  header.bV5Size = sizeof(header);
  header.bV5Width = static_cast<LONG>(width);
  // Positive: bottom-up, which every reader understands.
  header.bV5Height = static_cast<LONG>(height);
  header.bV5Planes = 1;
  header.bV5BitCount = 32;
  header.bV5Compression = BI_BITFIELDS;
  header.bV5SizeImage = static_cast<DWORD>(pixels);
  header.bV5RedMask = 0x00FF0000;
  header.bV5GreenMask = 0x0000FF00;
  header.bV5BlueMask = 0x000000FF;
  header.bV5AlphaMask = 0xFF000000;
  header.bV5CSType = LCS_sRGB;
  header.bV5Intent = LCS_GM_IMAGES;

  Bytes dib(sizeof(header) + pixels);
  std::memcpy(dib.data(), &header, sizeof(header));
  uint8_t* rows = dib.data() + sizeof(header);
  for (UINT y = 0; y < height; y++) {
    std::memcpy(rows + static_cast<size_t>(y) * stride,
                top_down.data() + static_cast<size_t>(height - 1 - y) * stride,
                stride);
  }
  return dib;
}

const EncodableValue* Lookup(const EncodableMap& map, const char* key) {
  auto it = map.find(EncodableValue(key));
  return it == map.end() ? nullptr : &it->second;
}

// PNG bytes: offered as PNG (browsers, Office, chats) and as a bitmap
// (Paint and older apps), at the image's own size.
void CopyImage(HWND owner, const EncodableValue* args, Result& result) {
  const auto* png = args ? std::get_if<Bytes>(args) : nullptr;
  if (png == nullptr) {
    result->Error("bad-args", "copyImage takes PNG bytes");
    return;
  }
  std::optional<Bytes> dib = DibFromPng(*png);
  if (!dib) {
    result->Error("decode", "not a PNG");
    return;
  }
  if (auto failure =
          SetClipboard(owner, {{PngFormat(), *png}, {CF_DIBV5, *dib}})) {
    result->Error("clipboard", "the clipboard refused the image: " + *failure);
    return;
  }
  result->Success();
}

// {paths}: the files only (Explorer pastes the files themselves), plus the
// paths as text; never an image.
void CopyFiles(HWND owner, const EncodableValue* args, Result& result) {
  const auto* map = args ? std::get_if<EncodableMap>(args) : nullptr;
  const EncodableValue* value = map ? Lookup(*map, "paths") : nullptr;
  const auto* list = value ? std::get_if<EncodableList>(value) : nullptr;
  if (list == nullptr || list->empty()) {
    result->Error("bad-args", "no paths");
    return;
  }
  std::wstring files;  // each path and a NUL, then one more NUL
  std::wstring text;
  for (const EncodableValue& item : *list) {
    const auto* path = std::get_if<std::string>(&item);
    if (path == nullptr) {
      result->Error("bad-args", "paths must be strings");
      return;
    }
    std::wstring wide = Utf16FromUtf8(*path);
    if (!text.empty()) text += L"\r\n";
    text += wide;
    std::replace(wide.begin(), wide.end(), L'/', L'\\');
    files += wide;
    files += L'\0';
  }
  files += L'\0';

  DROPFILES drop = {};
  drop.pFiles = sizeof(drop);
  drop.fWide = TRUE;
  Bytes hdrop(sizeof(drop) + files.size() * sizeof(wchar_t));
  std::memcpy(hdrop.data(), &drop, sizeof(drop));
  std::memcpy(hdrop.data() + sizeof(drop), files.data(),
              files.size() * sizeof(wchar_t));

  const DWORD effect = DROPEFFECT_COPY;
  Bytes effect_bytes(sizeof(effect));
  std::memcpy(effect_bytes.data(), &effect, sizeof(effect));

  const wchar_t* chars = text.c_str();
  Bytes text_bytes(reinterpret_cast<const uint8_t*>(chars),
                   reinterpret_cast<const uint8_t*>(chars + text.size() + 1));

  if (auto failure = SetClipboard(owner, {{CF_HDROP, hdrop},
                                          {DropEffectFormat(), effect_bytes},
                                          {CF_UNICODETEXT, text_bytes}})) {
    result->Error("clipboard", "the clipboard refused the files: " + *failure);
    return;
  }
  result->Success();
}

// The clipboard's data for a MIME target; `text/uri-list` is the copied
// files' URIs, one per line, and `text/plain` comes as UTF-8. For tests.
void Read(const EncodableValue* args, Result& result) {
  const auto* target = args ? std::get_if<std::string>(args) : nullptr;
  if (target == nullptr) {
    result->Error("bad-args", "read takes a target name");
    return;
  }
  const UINT format = FormatForMime(*target);
  OpenClipboard clipboard(nullptr);
  HANDLE handle = clipboard.ok() && format != 0
                      ? ::GetClipboardData(format)
                      : nullptr;
  if (handle == nullptr) {
    result->Success();
    return;
  }
  Bytes out;
  if (format == CF_HDROP) {
    auto* drop = static_cast<HDROP>(handle);
    const UINT n = ::DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
    std::string list;
    for (UINT i = 0; i < n; i++) {
      std::wstring path(::DragQueryFileW(drop, i, nullptr, 0), L'\0');
      ::DragQueryFileW(drop, i, path.data(),
                       static_cast<UINT>(path.size() + 1));
      list += FileUri(path) + "\r\n";
    }
    out.assign(list.begin(), list.end());
  } else {
    const void* data = ::GlobalLock(handle);
    if (data == nullptr) {
      result->Success();
      return;
    }
    const size_t size = ::GlobalSize(handle);
    if (format == CF_UNICODETEXT) {
      const auto* chars = static_cast<const wchar_t*>(data);
      const size_t len = wcsnlen(chars, size / sizeof(wchar_t));
      const std::string utf8 = Utf8FromUtf16(std::wstring(chars, len).c_str());
      out.assign(utf8.begin(), utf8.end());
    } else {
      const auto* begin = static_cast<const uint8_t*>(data);
      out.assign(begin, begin + size);
    }
    ::GlobalUnlock(handle);
  }
  result->Success(EncodableValue(out));
}

// The formats on offer, as MIME names where one exists. For tests.
void Targets(Result& result) {
  EncodableList names;
  OpenClipboard clipboard(nullptr);
  if (clipboard.ok()) {
    for (UINT format = ::EnumClipboardFormats(0); format != 0;
         format = ::EnumClipboardFormats(format)) {
      EncodableValue name(MimeForFormat(format));
      if (std::find(names.begin(), names.end(), name) == names.end()) {
        names.push_back(name);
      }
    }
  }
  result->Success(EncodableValue(names));
}

// The shell's own Open with dialog (the list of apps for the file, More
// apps, Look for another app on this PC), opening the file once with the
// app picked. Answers false when nothing was picked.
void OpenWith(HWND owner, const EncodableValue* args, Result& result) {
  const auto* path = args ? std::get_if<std::string>(args) : nullptr;
  if (path == nullptr) {
    result->Error("bad-args", "openWith takes a path");
    return;
  }
  std::wstring file = Utf16FromUtf8(*path);
  std::replace(file.begin(), file.end(), L'/', L'\\');
  OPENASINFO info = {};
  info.pcszFile = file.c_str();
  // Open it now; don't offer to make the app the default.
  info.oaifInFlags = OAIF_EXEC | OAIF_HIDE_REGISTRATION;
  // Blocks (pumping messages) until the dialog closes and the app started.
  const HRESULT hr = ::SHOpenWithDialog(owner, &info);
  if (SUCCEEDED(hr)) {
    result->Success(EncodableValue(true));
  } else if (hr == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
    result->Success(EncodableValue(false));
  } else {
    result->Error("launch", "could not open the file (HRESULT " +
                                std::to_string(static_cast<long>(hr)) + ")");
  }
}

}  // namespace

ClipboardPlugin::ClipboardPlugin(flutter::BinaryMessenger* messenger,
                                 HWND window)
    : window_(window) {
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "loot_silo/clipboard",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<EncodableValue>& call, Result result) {
        const std::string& method = call.method_name();
        const EncodableValue* args = call.arguments();
        if (method == "copyImage") {
          CopyImage(window_, args, result);
        } else if (method == "copyFiles") {
          CopyFiles(window_, args, result);
        } else if (method == "read") {
          Read(args, result);
        } else if (method == "targets") {
          Targets(result);
        } else if (method == "openWith") {
          OpenWith(window_, args, result);
        } else {
          result->NotImplemented();
        }
      });
}

ClipboardPlugin::~ClipboardPlugin() {
  channel_->SetMethodCallHandler(nullptr);
}

import 'dart:ffi';

import 'package:ffi/ffi.dart';

typedef _ILCreateFromPathN = Pointer<Void> Function(Pointer<Utf16>);
typedef _ILFreeN = Void Function(Pointer<Void>);
typedef _ILFreeD = void Function(Pointer<Void>);
typedef _SHOpenN =
    Int32 Function(Pointer<Void>, Uint32, Pointer<Pointer<Void>>, Uint32);
typedef _SHOpenD =
    int Function(Pointer<Void>, int, Pointer<Pointer<Void>>, int);
typedef _CoInitN = Int32 Function(Pointer<Void>, Uint32);
typedef _CoInitD = int Function(Pointer<Void>, int);
typedef _CoUninitN = Void Function();
typedef _CoUninitD = void Function();
typedef _AllowFgN = Int32 Function(Uint32);
typedef _AllowFgD = int Function(int);

typedef _ShellExecuteN =
    IntPtr Function(
      IntPtr,
      Pointer<Utf16>,
      Pointer<Utf16>,
      Pointer<Utf16>,
      Pointer<Utf16>,
      Int32,
    );
typedef _ShellExecuteD =
    int Function(
      int,
      Pointer<Utf16>,
      Pointer<Utf16>,
      Pointer<Utf16>,
      Pointer<Utf16>,
      int,
    );

/// Opens [path] (a folder in Explorer, a file in its default app) by
/// handing the plain path to `ShellExecuteW`. A `file:` URL won't do: the
/// shell reads `#` as the start of a fragment, so `Enemy Bundle #4` became
/// `Enemy Bundle ` and nothing opened. Returns false when the shell fails.
bool shellOpen(String path) {
  final shellExecute = DynamicLibrary.open('shell32.dll')
      .lookupFunction<_ShellExecuteN, _ShellExecuteD>('ShellExecuteW');
  DynamicLibrary.open('user32.dll')
      .lookupFunction<_AllowFgN, _AllowFgD>('AllowSetForegroundWindow')(
    0xFFFFFFFF,
  );
  final verb = 'open'.toNativeUtf16();
  final file = path.toNativeUtf16();
  try {
    // SW_SHOWNORMAL; values above 32 mean success.
    return shellExecute(0, verb, file, nullptr, nullptr, 1) > 32;
  } finally {
    calloc.free(verb);
    calloc.free(file);
  }
}

/// Opens an Explorer window with [path] selected and focused, through
/// `SHOpenFolderAndSelectItems` (what Windows' own "Open file location"
/// uses). `explorer /select,` opens the folder but often leaves the file
/// unselected. Returns false when the shell call fails, e.g. no such file.
bool selectInExplorer(String path) {
  final shell32 = DynamicLibrary.open('shell32.dll');
  final ole32 = DynamicLibrary.open('ole32.dll');
  final user32 = DynamicLibrary.open('user32.dll');
  final createPidl = shell32
      .lookupFunction<_ILCreateFromPathN, _ILCreateFromPathN>(
        'ILCreateFromPathW',
      );
  final freePidl = shell32.lookupFunction<_ILFreeN, _ILFreeD>('ILFree');
  final openAndSelect = shell32.lookupFunction<_SHOpenN, _SHOpenD>(
    'SHOpenFolderAndSelectItems',
  );
  final coInit = ole32.lookupFunction<_CoInitN, _CoInitD>('CoInitializeEx');
  final coUninit = ole32.lookupFunction<_CoUninitN, _CoUninitD>(
    'CoUninitialize',
  );
  final allowForeground = user32.lookupFunction<_AllowFgN, _AllowFgD>(
    'AllowSetForegroundWindow',
  );

  // The app has the foreground; let Explorer take it so its window comes
  // to the front instead of flashing in the taskbar. ASFW_ANY = -1.
  allowForeground(0xFFFFFFFF);
  // COINIT_APARTMENTTHREADED. S_OK/S_FALSE must be paired with an
  // uninitialize; RPC_E_CHANGED_MODE means COM is already up, which is fine.
  final initHr = coInit(nullptr, 0x2);
  final native = path.toNativeUtf16();
  try {
    final pidl = createPidl(native);
    if (pidl == nullptr) return false;
    try {
      // No child items: the shell opens pidl's folder and selects pidl.
      return openAndSelect(pidl, 0, nullptr, 0) >= 0;
    } finally {
      freePidl(pidl);
    }
  } finally {
    calloc.free(native);
    if (initHr >= 0) coUninit();
  }
}

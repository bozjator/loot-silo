import 'package:clock/clock.dart';
import 'package:flutter/gestures.dart' show kDoubleTapTimeout;

/// Tells a second click on the same card soon after the first (a
/// double-click) from a single click, without a double-tap recognizer,
/// which would hold every single click back until the double-click time
/// had passed.
class DoubleClick<T> {
  (T, DateTime)? _last;

  /// Whether this click on [key] is the second of a double-click; otherwise
  /// it is remembered as a first click.
  bool second(T key) {
    // `clock` rather than DateTime: widget tests' fake time moves it.
    final now = clock.now();
    final last = _last;
    if (last != null &&
        last.$1 == key &&
        now.difference(last.$2) < kDoubleTapTimeout) {
      _last = null;
      return true;
    }
    _last = (key, now);
    return false;
  }

  /// Forgets the last click (a Ctrl- or Shift-click selects instead).
  void reset() => _last = null;
}

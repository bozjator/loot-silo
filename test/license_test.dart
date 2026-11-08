import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// M53: the license is MIT plus the Commons Clause (no resale).
void main() {
  test('LICENSE is the Commons Clause over MIT, licensor bozjator', () {
    final text = File('LICENSE').readAsStringSync();
    expect(text, startsWith('"Commons Clause" License Condition v1.0'));
    expect(text, contains('the right to\nSell the Software'));
    expect(text, contains('Software: Loot Silo'));
    expect(text, contains('License: MIT'));
    expect(text, contains('Licensor: bozjator'));
    expect(text, contains('MIT License'));
    expect(text, contains('Copyright (c) 2026 bozjator'));
    expect(
      text,
      contains('Permission is hereby granted, free of charge, to any person'),
    );
    expect(text, contains('THE SOFTWARE IS PROVIDED "AS IS"'));
  });
}

// Issue #1: when the file picker cannot open, say so; on Linux, what is missing.

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/utilities/beam/file_picker_failure.dart';

void main() {
  test('elsewhere: try again', () {
    expect(
      filePickerFailureText(linux: false),
      "Campfire couldn't open the file picker. Try again.",
    );
    expect(
      filePickerFailureText(app: 'BEAM Campfire', linux: false),
      "BEAM Campfire couldn't open the file picker. Try again.",
    );
  });

  test('on Linux: names the file chooser service to install', () {
    final t = filePickerFailureText(linux: true);
    expect(t, startsWith("Campfire couldn't open the file picker."));
    expect(t, contains('xdg-desktop-portal'));
    expect(t, contains('xdg-desktop-portal-gtk'));
    expect(t, contains('xdg-desktop-portal-kde'));
  });
}

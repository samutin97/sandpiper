import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/router/deep_linking/url_protocol/windows_protocol.dart';

/// B-08: the command line of the URL handler names the executable in quotes. Only the command line is
/// built here; nothing is written to the registry.
void main() {
  final handler = WindowsProtocolHandler();

  test('a path with a space is quoted, the link passed as one argument', () {
    expect(
      handler.command(r'C:\Program Files\Sandpiper\Hiddify.exe', null),
      r'"C:\Program Files\Sandpiper\Hiddify.exe" "%1"',
    );
  });

  test('given arguments are quoted as before', () {
    expect(handler.command(r'C:\App\app.exe', ['--open', '%s']), r'"C:\App\app.exe" "--open" "%1"');
  });
}

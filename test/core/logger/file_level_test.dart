import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/logger/logger_setup.dart';
import 'package:hiddify/core/logger/sinks/file_sink.dart';
import 'package:logging/logging.dart';

void main() {
  // Windows acceptance of 5.9.8-sp.11: the warnings of a repaired local port were on the logs page
  // only, not in app.log, which a report carries.
  test('warnings and errors go to app.log, quieter lines do not', () async {
    final dir = await Directory.systemTemp.createTemp('app_log_level');
    addTearDown(() => dir.delete(recursive: true));
    Logger.root.level = Level.ALL;
    logAddFile('${dir.path}/app.log');
    final log = Logger('test');
    log.info('an ordinary line');
    log.warning('the core could not open the local port 50100 (mixed-port): using 30001');
    log.severe('something failed');
    await Future<void>.delayed(Duration.zero);
    logSetFileEnabled(false);
    closeLogFile();
    final text = File('${dir.path}/app.log').readAsStringSync();
    expect(text, contains('could not open the local port'));
    expect(text, contains('something failed'));
    expect(text, isNot(contains('an ordinary line')));
  });
}

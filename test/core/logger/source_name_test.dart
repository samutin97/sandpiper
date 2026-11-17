import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/logger/logger_setup.dart';
import 'package:hiddify/utils/custom_loggers.dart';

void main() {
  group('source names in the logs', () {
    test('class and file names lose the upstream name', () {
      expect(neutralSourceName('HiddifyCoreService'), 'CoreService');
      expect(neutralSourceName('_HiddifyCoreNotifier'), '_CoreNotifier');
      expect(neutralSourceName('HiddifyCoreService.start (hiddify_core_service.dart:12)'), 'CoreService.start (core_service.dart:12)');
    });

    test('other names stay', () {
      for (final name in ['ProfileRepository', 'Hiddify', 'hiddify', 'MyHiddifyThing', 'core', 'nothiddify_x.dart']) {
        expect(neutralSourceName(name), name);
      }
    });

    test('a logger made by a factory carries the neutral name', () {
      expect(infraLogger('HiddifyCoreService').fullName, 'infra.CoreService');
      expect(coreLogger('HiddifyCoreServiceProvider').fullName, 'core.CoreServiceProvider');
      expect(appLogger('ConnectionNotifier').fullName, 'app.ConnectionNotifier');
    });

    test('the origin of a record is neutral too', () {
      final stack = StackTrace.fromString(
        '#0      HiddifyCoreService.start (package:hiddify/hiddifycore/hiddify_core_service.dart:88:12)\n'
        '#1      main (package:hiddify/main.dart:5:3)',
      );
      expect(originOf(stack), 'CoreService.start (core_service.dart:88)');
    });
  });
}

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/http_client/dio_http_client.dart';
import 'package:hiddify/core/model/app_info_entity.dart';

const _appAgent = 'HiddifyNext/9.9.9 (android)';

void main() {
  late HttpServer server;
  late String base;
  late List<String?> seen;

  setUp(() async {
    seen = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    unawaited(
      server.forEach((request) {
        seen.add(request.headers.value(HttpHeaders.userAgentHeader));
        if (request.uri.path == '/redirect') {
          request.response
            ..statusCode = HttpStatus.found
            ..headers.set(HttpHeaders.locationHeader, '/final');
        } else {
          request.response.write('ok');
        }
        request.response.close();
      }),
    );
  });

  tearDown(() => server.close(force: true));

  DioHttpClient client() => DioHttpClient(timeout: const Duration(seconds: 5), userAgent: _appAgent, debug: false);

  test('a request without a user agent of its own carries the app one', () async {
    await client().get('$base/plain');

    expect(seen, [_appAgent]);
  });

  test('a user agent given for the request is the one sent', () async {
    await client().get('$base/plain', userAgent: 'HiddifyNextX/9.9.9');

    expect(seen, ['HiddifyNextX/9.9.9']);
  });

  test('a redirect is followed with the same user agent', () async {
    await client().get('$base/redirect');

    expect(seen, [_appAgent, _appAgent]);
  });

  test('a download carries it too', () async {
    final file = File('${Directory.systemTemp.path}/ua_download_${DateTime.now().microsecondsSinceEpoch}');
    addTearDown(() => file.existsSync() ? file.deleteSync() : null);

    await client().download('$base/plain', file.path);

    expect(seen, [_appAgent]);
  });

  test('the user agent of dart:io is never sent, whatever asks for it', () async {
    await client().get('$base/plain', userAgent: 'Dart/3.10 (dart:io)');
    await client().get('$base/plain', userAgent: '');

    expect(seen, [_appAgent, _appAgent]);
    expect(seen.where((agent) => agent?.startsWith('Dart') ?? true), isEmpty);
  });

  group('the subscription user agent', () {
    test('is the minimum Hiddify Manager needs for the hiddify-core format', () {
      expect(AppInfoEntity.userAgentFor('5.9.8', 'android'), 'HiddifyNext/5.9.8 (android)');
    });

    test('carries the upstream version, not the fork suffix', () {
      expect(AppInfoEntity.userAgentFor('5.9.8-sp.1', 'android'), 'HiddifyNext/5.9.8 (android)');
      expect(AppInfoEntity.upstreamVersion('5.9.8-sp.1+50908'), '5.9.8');
    });

    test('matches the panel patterns', () {
      final ua = AppInfoEntity.userAgentFor('5.9.8-sp.1', 'android');
      // hiddifypanel/proxy_v3/client_core_auto.py: hiddify-core + singbox
      expect(RegExp('^(HiddifyNext|Dart|SFI|SFA)', caseSensitive: false).hasMatch(ua), isTrue);
      // hutils/flask.py: the version after the slash, >= 5 for the newest features
      final version = RegExp(r'/(\d+\.\d+(\.\d+)?)').firstMatch(ua)!.group(1)!;
      expect(int.parse(version.split('.').first), greaterThanOrEqualTo(5));
    });
  });
}

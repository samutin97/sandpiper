import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/logger/log_scrubber.dart';

void main() {
  group('scrubSecrets', () {
    test("masks the other subscription of a profile's pair, as a header, a pair or alone", () {
      const link = 'aHR0cHM6Ly9leGFtcGxlLm9yZy9zdWIvd2FycC10b2tlbg';
      for (final line in [
        'profile-exits: v=1;cur=main;alt=warp;alt-url=$link',
        'headers {profile-exits: v=1;cur=main;alt=warp;alt-url=$link, profile-title: x}',
        'the other one is $link',
        '"alt-url": "$link"',
        'alt_url=$link',
      ]) {
        final out = scrubSecrets(line);
        expect(out, isNot(contains(link)), reason: line);
        expect(out, isNot(contains('aHR0cHM6')), reason: line);
      }
    });

    test('masks whole proxy and profile links', () {
      final out = scrubSecrets(
        'adding vless://0f1e2d3c-1111-2222-3333-444455556666@a.example.com:443?pbk=ABC#Home and vpn://AAAAeJzzSM3JyVcozy',
      );
      expect(out, isNot(contains('a.example.com')));
      expect(out, isNot(contains('0f1e2d3c')));
      expect(out, contains('vless://[redacted]'));
      expect(out, contains('vpn://[redacted]'));
    });

    test('keeps the host of an https URL, not its path or query', () {
      final out = scrubSecrets('updating https://panel.example.com/sec/ret/token123/?x=1 failed');
      expect(out, contains('https://panel.example.com/[redacted]'));
      expect(out, isNot(contains('token123')));
    });

    test('masks key=value secrets, UUIDs and 32-byte keys', () {
      final out = scrubSecrets(
        'password=hunter2 private_key: "kE0Z4Q8m3uH6x9yQ1w2e3r4t5y6u7i8o9p0a1s2d3f4=" uuid 0f1e2d3c-1111-2222-3333-444455556666',
      );
      expect(out, isNot(contains('hunter2')));
      expect(out, isNot(contains('kE0Z4Q8m3uH6x9yQ')));
      expect(out, isNot(contains('0f1e2d3c-1111')));
    });

    test('masks IPv4 and IPv6 addresses but not times and versions', () {
      final out = scrubSecrets('12:30:45.123 dial 203.0.113.7:51820 and [2001:db8::1]:443 and fe80::1 via sing-box 1.15.0');
      expect(out, contains('12:30:45.123'));
      expect(out, contains('1.15.0'));
      expect(out, isNot(contains('203.0.113.7')));
      expect(out, isNot(contains('2001:db8::1')));
      expect(out, isNot(contains('fe80::1')));
    });

    test('leaves ordinary text alone', () {
      const line = 'connection status: connected (profile Home, 3 proxies)';
      expect(scrubSecrets(line), line);
    });
  });
}

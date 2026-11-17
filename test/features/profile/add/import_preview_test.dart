import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/profile/add/import_preview.dart';
import 'package:hiddify/features/profile/data/profile_parser.dart';
import 'package:hiddify/features/profile/notifier/profile_notifier.dart';
import 'package:hiddify/gen/translations.g.dart';

void main() {
  group('previewImport: subscriptions', () {
    test('an https subscription shows its host and name, nothing refused', () {
      final p = previewImport('https://panel.example.com/abc/def/?x=1#Home');
      expect(p.remote, isTrue);
      expect(p.host, 'panel.example.com');
      expect(p.name, 'Home');
      expect(p.refusal, isNull);
    });

    test('a non-default port is part of the host', () {
      expect(previewImport('https://panel.example.com:8443/sub').host, 'panel.example.com:8443');
    });

    test('an http subscription is refused before any download', () {
      final p = previewImport('http://panel.example.com/sub/token');
      expect(p.remote, isTrue);
      expect(p.refusal, ImportRefusal.insecureHttp);
    });

    test('a sandpiper deep link shows the subscription it points to', () {
      final p = previewImport('sandpiper://import/https://sub.example.org/x?token=1#Mine');
      expect(p.remote, isTrue);
      expect(p.host, 'sub.example.org');
      expect(p.name, 'Mine');
      expect(p.refusal, isNull);
    });

    test('a deep link to an http subscription is refused', () {
      expect(previewImport('sandpiper://import?url=http%3A%2F%2Fsub.example.org%2Fx').refusal, ImportRefusal.insecureHttp);
    });
  });

  group('previewImport: configs given in full', () {
    test('proxy links show their servers', () {
      const text = 'vless://uuid@a.example.com:443?security=reality#A\n'
          'hy2://pass@b.example.com:8443#B\n'
          'trojan://pw@c.example.com:2083#C\n'
          'ss://xyz@d.example.com:8388#D\n';
      final p = previewImport(text);
      expect(p.remote, isFalse);
      expect(p.servers, ['a.example.com:443', 'b.example.com:8443', 'c.example.com:2083']);
      expect(p.serverCount, 4);
      expect(p.name, 'A');
    });

    test('base64 of links is read too', () {
      final p = previewImport(base64.encode(utf8.encode('vless://u@e.example.com:443#E')));
      expect(p.servers, ['e.example.com:443']);
    });

    test('vmess shows the address inside its JSON', () {
      final vmess = base64.encode(utf8.encode(jsonEncode({'add': 'f.example.com', 'port': '443', 'ps': 'F'})));
      expect(previewImport('vmess://$vmess').servers, ['f.example.com:443']);
    });

    test('an AmneziaWG/WireGuard .conf shows its endpoint', () {
      const conf = '[Interface]\nPrivateKey = x\nJc = 4\n\n[Peer]\nPublicKey = y\nEndpoint = 203.0.113.7:51820\n';
      final p = previewImport(conf);
      expect(p.servers, ['203.0.113.7:51820']);
      expect(p.remote, isFalse);
    });

    test('a sing-box JSON shows the servers of its outbounds and endpoints', () {
      final json = jsonEncode({
        'outbounds': [
          {'type': 'vless', 'tag': 'a', 'server': 'g.example.com', 'server_port': 443},
          {'type': 'direct', 'tag': 'direct'},
        ],
        'endpoints': [
          {
            'type': 'awg',
            'tag': 'w',
            'peers': [
              {'address': '198.51.100.2', 'port': 8443},
            ],
          },
        ],
      });
      expect(previewImport(json).servers, ['g.example.com:443', '198.51.100.2:8443']);
    });
  });

  group('previewImport: AmneziaWG (D-07)', () {
    String amneziaKey({String description = 'Home AWG'}) {
      const conf =
          '[Interface]\nPrivateKey = cHJpdmF0ZS1rZXktbm90LXJlYWwtMDEyMzQ1Njc4OWFi\nJc = 4\n'
          '[Peer]\nPublicKey = x\nEndpoint = 203.0.113.5:51820\n';
      final json = jsonEncode({
        'description': description,
        'containers': [
          {
            'container': 'amnezia-awg',
            'awg': {
              'last_config': jsonEncode({'config': conf}),
            },
          },
        ],
      });
      final raw = utf8.encode(json);
      final packed = ZLibEncoder().convert(raw);
      final length = raw.length;
      final bytes = [length >> 24 & 255, length >> 16 & 255, length >> 8 & 255, length & 255, ...packed];
      return 'vpn://${base64Url.encode(bytes).replaceAll('=', '')}';
    }

    test('a vpn:// key shows AmneziaWG, its name and endpoint, never its payload', () {
      final key = amneziaKey();
      final p = previewImport(key);
      expect(p.type, 'AmneziaWG');
      expect(p.name, 'Home AWG');
      expect(p.servers, ['203.0.113.5:51820']);
      expect(p.remote, isFalse);
      final t = AppLocale.en.buildSync();
      final message = AddProfileNotifier.importDialogMessage(
        t,
        p,
        ImportSource.clipboard,
        activate: false,
        tunneled: true,
      );
      expect(message, isNot(contains(key.substring(6, 40))));
      expect(message, isNot(contains('cHJpdmF0ZS1rZXk')));
      expect(message, contains('AmneziaWG'));
      expect(message, contains('203.0.113.5:51820'));
    });

    test('a key that does not read shows the type only', () {
      final p = previewImport('vpn://AAAAAAnotreally');
      expect(p.type, 'AmneziaWG');
      expect(p.servers, isEmpty);
    });

    test('a .conf shows AmneziaWG or WireGuard and the endpoint, not the key', () {
      const awg = '[Interface]\nPrivateKey = cHJpdmF0ZQ==\nJc = 4\n[Peer]\nEndpoint = 203.0.113.7:51821\n';
      const wg = '[Interface]\nPrivateKey = cHJpdmF0ZQ==\n[Peer]\nEndpoint = 203.0.113.8:51820\n';
      expect(previewImport(awg).type, 'AmneziaWG');
      expect(previewImport(awg).servers, ['203.0.113.7:51821']);
      expect(previewImport(wg).type, 'WireGuard');
      expect(previewImport(awg).name, isEmpty);
    });

    test('a link whose host would be its payload shows no server', () {
      expect(previewImport('ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ=#x').servers, isEmpty);
    });
  });

  group('ProfileParser.isHttpsUrl', () {
    test('only https with a host', () {
      expect(ProfileParser.isHttpsUrl('https://a.example.com/x'), isTrue);
      expect(ProfileParser.isHttpsUrl(' HTTPS://a.example.com/x '), isTrue);
      expect(ProfileParser.isHttpsUrl('http://a.example.com/x'), isFalse);
      expect(ProfileParser.isHttpsUrl('ftp://a.example.com/x'), isFalse);
      expect(ProfileParser.isHttpsUrl('https:///x'), isFalse);
    });
  });

  group('the import dialog', () {
    final t = AppLocale.en.buildSync();

    test('says where it comes from and that the profile is not selected', () {
      final message = AddProfileNotifier.importDialogMessage(
        t,
        previewImport('https://panel.example.com/sub#Home'),
        ImportSource.deepLink,
        activate: false,
        tunneled: true,
      );
      expect(message, contains(t.fork.import.source.deepLink));
      expect(message, contains('panel.example.com'));
      expect(message, contains('Home'));
      expect(message, contains(t.fork.import.notActivated));
      expect(message, isNot(contains(t.fork.import.direct(host: 'panel.example.com'))));
      // SP3-05: and that the download goes through the tunnel
      expect(message, contains(t.fork.import.tunneled));
    });

    test('warns that the download goes around the tunnel', () {
      final message = AddProfileNotifier.importDialogMessage(
        t,
        previewImport('https://panel.example.com/sub'),
        ImportSource.clipboard,
        activate: true,
        tunneled: false,
      );
      expect(message, contains(t.fork.import.firstActivated));
      expect(message, contains(t.fork.import.direct(host: 'panel.example.com')));
      expect(message, isNot(contains(t.fork.import.tunneled)));
    });

    test('lists a few servers of a config and counts the rest', () {
      final message = AddProfileNotifier.importDialogMessage(
        t,
        previewImport(List.generate(5, (i) => 'vless://u@s$i.example.com:443#S$i').join('\n')),
        ImportSource.file,
        activate: false,
        tunneled: false,
      );
      expect(message, contains('s0.example.com:443'));
      expect(message, contains(t.fork.import.more(n: 2)));
      // a config is not downloaded: no warning about a direct download
      expect(message, isNot(contains(t.fork.import.direct(host: ''))));
    });
  });
}

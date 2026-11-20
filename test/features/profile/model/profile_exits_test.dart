import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/model/profile_exits.dart';
import 'package:hiddify/features/profile/notifier/exit_choice_notifier.dart';

const _main = 'https://example.org/sub/main-token';
const _warp = 'https://example.org/sub/warp-token';

String _b64(String text) => base64Url.encode(utf8.encode(text)).replaceAll('=', '');

String _header({String v = '1', String cur = 'main', String alt = 'warp', String? url}) =>
    'v=$v;cur=$cur;alt=$alt;alt-url=${_b64(url ?? _warp)}';

RemoteProfileEntity _profile({String header = '', UserOverride? override, String url = _main}) => RemoteProfileEntity(
  id: 'p1',
  active: true,
  name: 'subscription',
  url: url,
  lastUpdate: DateTime(2026, 11, 20),
  populatedHeaders: {if (header.isNotEmpty) ProfileExits.headerName: header},
  userOverride: override,
);

void main() {
  group('profile-exits header', () {
    test('reads a pair', () {
      final exits = ProfileExits.parse(_header());
      expect(exits, isNotNull);
      expect(exits!.current, ExitRole.main);
      expect(exits.alternative, ExitRole.warp);
      expect(exits.alternativeUrl, _warp);
    });

    test('the pair of the other record points back', () {
      final exits = ProfileExits.parse(_header(cur: 'warp', alt: 'main', url: _main))!;
      expect(exits.current, ExitRole.warp);
      expect(exits.alternativeUrl, _main);
    });

    test('keys and roles in any case, spaces and empty pairs do not matter, unknown keys are skipped', () {
      final exits = ProfileExits.parse(' V = 1 ; CUR = Main ; ; Alt=WARP ; later=2 ; ALT-URL = ${_b64(_warp)} ');
      expect(exits?.current, ExitRole.main);
      expect(exits?.alternative, ExitRole.warp);
      expect(exits?.alternativeUrl, _warp);
    });

    test('the pair kept is in one canonical form that reads back the same', () {
      final exits = ProfileExits.parse(' V=1;CUR=MAIN;ALT=warp;alt-url=${_b64(_warp)} ')!;
      expect(exits.encode(), 'v=1;cur=main;alt=warp;alt-url=${_b64(_warp)}');
      expect(ProfileExits.parse(exits.encode()), exits);
    });

    test('no header, or an empty one, is no pair and not a dropped header', () {
      for (final value in <Object?>[null, '', '   ']) {
        final verdict = ProfileExits.parseVerdict(value);
        expect(verdict.exits, isNull);
        expect(verdict.dropped, isFalse, reason: '$value');
      }
    });

    test('a version this app does not know is dropped whole', () {
      for (final v in ['2', '0', '1.1', '01', '']) {
        final verdict = ProfileExits.parseVerdict(_header(v: v));
        expect(verdict.exits, isNull, reason: v);
        expect(verdict.dropped, isTrue, reason: v);
      }
      expect(ProfileExits.parseVerdict(_header(v: '2')).reason, ExitsDrop.unknownVersion);
      // no version at all
      expect(ProfileExits.parseVerdict('cur=main;alt=warp;alt-url=${_b64(_warp)}').dropped, isTrue);
    });

    test('anything that does not read is dropped whole', () {
      final bad = <String>[
        // roles
        _header(alt: 'main'),
        _header(cur: 'warp'),
        _header(cur: 'psiphon'),
        _header(alt: ''),
        // the link
        'v=1;cur=main;alt=warp',
        'v=1;cur=main;alt=warp;alt-url=',
        'v=1;cur=main;alt=warp;alt-url=${_b64(_warp)}=',
        'v=1;cur=main;alt=warp;alt-url=!!!notbase64???',
        'v=1;cur=main;alt=warp;alt-url=a',
        'v=1;cur=main;alt=warp;alt-url=${_b64('http://example.org/sub/x')}',
        'v=1;cur=main;alt=warp;alt-url=${_b64('not a link')}',
        'v=1;cur=main;alt=warp;alt-url=${_b64('https://example.org/sub/x y')}',
        'v=1;cur=main;alt=warp;alt-url=${_b64('https:///only-path')}',
        'v=1;cur=main;alt=warp;alt-url=${_b64('https://example.org/${'a' * 2100}')}',
        // a key twice, a pair without a value sign, a byte that is not ASCII
        '${_header()};cur=main',
        '${_header()};junk',
        '${_header()};x=ы',
      ];
      for (final value in bad) {
        final verdict = ProfileExits.parseVerdict(value);
        expect(verdict.exits, isNull, reason: value);
        expect(verdict.dropped, isTrue, reason: value);
      }
      expect(ProfileExits.parse(42), isNull);
      expect(ProfileExits.parse('v=1;' * 1200), isNull);
    });

    test('a list of one value is that value; of more, nothing', () {
      expect(ProfileExits.parse([_header()]), isNotNull);
      expect(ProfileExits.parse([_header(), _header()]), isNull);
    });

    test('the text of a pair never shows the link', () {
      final exits = ProfileExits.parse(_header())!;
      expect('$exits', isNot(contains('warp-token')));
      expect('$exits', isNot(contains(_b64(_warp))));
    });
  });

  group('the host of the pair', () {
    String header(String url) => _header(url: url);
    bool accepted(String url, String source) => ProfileExits.parse(header(url), sourceUrl: source) != null;

    test('is the host of the subscription that sent the header', () {
      expect(accepted(_warp, _main), isTrue);
      expect(accepted('https://example.org/other/path?x=1', _main), isTrue);
    });

    test('in any case', () {
      expect(accepted('https://EXAMPLE.org/sub/warp-token', _main), isTrue);
      expect(accepted(_warp, 'https://Example.ORG/sub/main-token'), isTrue);
    });

    test('another host is dropped whole, and so is a host of another level', () {
      expect(accepted('https://example.net/sub/warp-token', _main), isFalse);
      expect(accepted('https://sub.example.org/sub/warp-token', _main), isFalse);
      expect(accepted('https://example.org.evil.example/sub/x', _main), isFalse);
      expect(accepted(_warp, 'https://sub.example.org/sub/main-token'), isFalse);
      expect(ProfileExits.parseVerdict(header('https://example.net/x'), sourceUrl: _main).dropped, isTrue);
    });

    test('the port is the same too', () {
      expect(accepted('https://example.org:8443/sub/x', _main), isFalse);
      expect(accepted('https://example.org:443/sub/x', _main), isTrue, reason: '443 is the https port');
      expect(accepted('https://example.org:8443/sub/x', 'https://example.org:8443/sub/y'), isTrue);
    });

    test('without a source there is no check (a header already kept)', () {
      expect(ProfileExits.parse(header('https://example.net/x')), isNotNull);
    });
  });

  group('the choice of a profile', () {
    test('is offered only with a valid pair', () {
      expect(ExitChoice.offered(_profile()), isFalse);
      expect(ExitChoice.offered(_profile(header: 'v=2;cur=main')), isFalse);
      expect(ExitChoice.offered(_profile(header: _header())), isTrue);
      expect(ExitChoice.current(_profile(header: _header())), ExitRole.main);
      expect(ExitChoice.current(_profile()), isNull);
    });

    test("warp from the profile's own link takes the pair's link and keeps the other choices", () {
      final profile = _profile(
        header: _header(),
        override: const UserOverride(name: 'mine', keepTop: 5),
      );
      final next = ExitChoice.overrideFor(profile, ExitRole.warp)!;
      expect(next.exitUrl, _warp);
      expect(next.name, 'mine');
      expect(next.keepTop, 5);
      expect(profile.fetchUrl, _main, reason: 'the profile itself is not changed');
    });

    test("back from the pair goes to the profile's own link", () {
      final onWarp = _profile(
        header: _header(cur: 'warp', alt: 'main', url: _main),
        override: const UserOverride(exitUrl: _warp),
      );
      expect(onWarp.fetchUrl, _warp);
      final next = ExitChoice.overrideFor(onWarp, ExitRole.main)!;
      expect(next.exitUrl, isNull);
      expect(onWarp.copyWith(userOverride: next).fetchUrl, _main);
    });

    test('nothing to do for the way out already in use, or without a pair', () {
      expect(ExitChoice.overrideFor(_profile(header: _header()), ExitRole.main), isNull);
      expect(ExitChoice.overrideFor(_profile(), ExitRole.warp), isNull);
    });

    test('an update that took the profile back to its own link is told', () {
      final onWarp = _profile(override: const UserOverride(exitUrl: _warp));
      expect(ExitChoice.fellBack(onWarp, onWarp.copyWith(userOverride: const UserOverride())), isTrue);
      expect(ExitChoice.fellBack(onWarp, onWarp), isFalse);
      expect(ExitChoice.fellBack(_profile(), _profile()), isFalse);
      expect(ExitChoice.fellBack(onWarp, null), isFalse);
    });
  });

  group("the profile's saved choices", () {
    test('a profile saved by 5.9.8-sp.13 has no pair and no way out chosen', () {
      final override = UserOverride.fromStr('{"version":3,"name":"x","keepTop":4,"adminPreference":"unset"}')!;
      expect(override.exitUrl, isNull);
      expect(_profile(override: override).fetchUrl, _main);
    });

    test("the link of the pair survives a save and a read, and the profile's own link stays", () {
      final override = UserOverride.fromStr(const UserOverride(exitUrl: _warp, name: 'x').toStr())!;
      final profile = _profile(override: override);
      expect(profile.fetchUrl, _warp);
      expect(profile.url, _main);
    });

    test('an exit link that is not an https one is not used', () {
      for (final bad in ['http://example.org/x', 'junk', '']) {
        expect(
          _profile(override: UserOverride(exitUrl: bad)).fetchUrl,
          _main,
          reason: bad,
        );
      }
    });
  });
}

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/profile/data/profile_parser.dart';
import 'package:hiddify/features/profile/model/profile_policy.dart';

// The same synthetic policy and garbage as hiddify-core v2/tiered (hardened_policy_test.go): the app
// and the core must read a header the same way.
const samplePolicy =
    'v=1; n=2:545:main; n=3:545:main; n=1:544:compact; n=4:444:compact; n=5:435:alt-tls;'
    ' n=6:335:borrowed-sni; n=7:335:borrowed-sni; n=9:335:udp; n=10:424:udp+ip-risk;'
    ' t=auto:2,3; t=auto:1,4; t=fallback:5,6,7; t=fallback:9; t=last-resort,confirm,max=60:10; fail=2; up=900';

const sampleCanonical =
    'v=1;n=2:545:main;n=3:545:main;n=1:544:compact;n=4:444:compact;n=5:435:alt-tls;'
    'n=6:335:borrowed-sni;n=7:335:borrowed-sni;n=9:335:udp;n=10:424:udp+ip-risk;'
    't=auto:2,3;t=auto:1,4;t=fallback:5,6,7;t=fallback:9;t=last-resort,confirm,max=60:10;fail=2;up=900';

const sampleTags = [
  '1 Alpha gRPC compact',
  '2 Bravo gRPC',
  '3 Charlie XHTTP',
  '4 Delta XHTTP compact',
  '5 Echo Naive',
  '6 Foxtrot gRPC two',
  '7 Golf XHTTP two',
  '9 India HTTP3',
  '10 Juliet WG',
];

void main() {
  test('the sample: nodes, tiers, parameters, the canonical form of the core', () {
    final p = ProfilePolicy.parse(samplePolicy)!;
    expect(p.nodes, hasLength(9));
    expect(p.tiers.map((t) => t.mode), [
      TierMode.auto,
      TierMode.auto,
      TierMode.fallback,
      TierMode.fallback,
      TierMode.lastResort,
    ]);
    expect(p.tiers.last.confirm, isTrue);
    expect(p.tiers.last.maxMinutes, 60);
    expect(p.encode(), sampleCanonical);
    expect(ProfilePolicy.parse(p.encode()), p);
    expect(p.ttl, const Duration(days: 7));
    final last = p.nodes.last;
    expect(last.scores, const PolicyScores(reliability: 4, stealth: 2, security: 4));
    expect(last.captions, ['udp', 'ip-risk']);
  });

  test('bind: by the number a name starts with, 1 is not 10, scored proxies outside tiers are manual', () {
    final places = ProfilePolicy.parse(samplePolicy)!.bind(sampleTags);
    expect(places['2 Bravo gRPC']!.mode, TierMode.auto);
    expect(places['1 Alpha gRPC compact']!.tier, 1);
    expect(places['9 India HTTP3']!.mode, TierMode.fallback);
    expect(places['10 Juliet WG']!.mode, TierMode.lastResort);
    final scoredOnly = ProfilePolicy.parse('v=1;n=5:333;t=auto:1')!.bind(sampleTags);
    expect(scoredOnly['5 Echo Naive']!.mode, TierMode.manual);
    expect(scoredOnly['5 Echo Naive']!.node!.scores.reliability, 3);
    expect(scoredOnly.containsKey('2 Bravo gRPC'), isFalse);
  });

  test('a proxy named in several tiers (number and name) is in the strictest, as in the core', () {
    final alias = ProfilePolicy.parse('v=1;t=auto:@10%20Juliet%20WG,2;t=last-resort,confirm:10')!.bind(sampleTags);
    expect(alias['10 Juliet WG']!.mode, TierMode.lastResort);
    expect(alias['10 Juliet WG']!.tier, 1);
    expect(alias['2 Bravo gRPC']!.mode, TierMode.auto);
    final manual = ProfilePolicy.parse('v=1;t=auto:2,3;t=manual:@2%20Bravo%20gRPC')!.bind(sampleTags);
    expect(manual['2 Bravo gRPC']!.mode, TierMode.manual);
    // of equal tiers the first
    final equal = ProfilePolicy.parse('v=1;t=auto:2;t=auto:@2%20Bravo%20gRPC,3')!.bind(sampleTags);
    expect(equal['2 Bravo gRPC']!.tier, 0);
  });

  test('a header whose canonical form is over 2048 bytes is no policy, as in the core', () {
    const params = ';up=1;chk=1;hold=1;ttl=1'; // canonical: 6 bytes more
    final b = StringBuffer('v=1;t=auto:1');
    final room = ProfilePolicy.maxLength - b.length - params.length;
    final nodes = (room + 97) ~/ 98;
    var names = room - 8 * nodes;
    for (var i = 0; i < nodes; i++) {
      var l = names - (nodes - 1 - i);
      if (l > 90) l = 90;
      names -= l;
      b.write(';n=@${String.fromCharCode(97 + i)}${'x' * (l - 1)}:555');
    }
    b.write(params);
    final header = b.toString();
    expect(header.length, ProfilePolicy.maxLength);
    expect(ProfilePolicy.parse(header), isNull);
    final short = '${header.substring(0, header.length - params.length)};up=300;chk=120';
    final p = ProfilePolicy.parse(short)!;
    expect(p.encode().length, lessThanOrEqualTo(ProfilePolicy.maxLength));
    expect(ProfilePolicy.parse(p.encode()), p);
  });

  test('references', () {
    const tags = ['1 One', '10 Ten', '11§hide§x', '2. Two', 'Plain name', '3 Three', '3 Three again', '04 Zero', 'Имя'];
    expect(const PolicyRef.number(1).resolve(tags), '1 One');
    expect(const PolicyRef.number(10).resolve(tags), '10 Ten');
    expect(const PolicyRef.number(11).resolve(tags), '11§hide§x');
    expect(const PolicyRef.number(2).resolve(tags), '2. Two');
    expect(const PolicyRef.number(3).resolve(tags), isNull); // two of them
    expect(const PolicyRef.number(4).resolve(tags), isNull); // "04" is no number
    expect(const PolicyRef.name('Plain name').resolve(tags), 'Plain name');
    final p = ProfilePolicy.parse('v=1;t=auto:@Plain%20name,@%D0%98%D0%BC%D1%8F')!;
    expect(p.bind(tags).keys, ['Plain name', 'Имя']);
    expect(p.encode(), 'v=1;t=auto:@Plain%20name,@%D0%98%D0%BC%D1%8F');
  });

  test('bounds, unknown keys and flags, the empty policy', () {
    final p = ProfilePolicy.parse(
      'v=1;t=auto,future-flag:1;t=last-resort,max=1000,confirm:2;fail=99;retry=1;up=5;hold=9999999;ttl=1;x-new=abc;n=1:111:some-new-key',
    )!;
    expect(p.params, {'fail': 4, 'retry': 2, 'up': 300, 'hold': 3600, 'ttl': 24});
    expect(p.tiers[1].maxMinutes, 240);
    expect(p.nodes.single.shownCaptions, isEmpty);
    final fallback = ProfilePolicy.parse('v=1;t=fallback,confirm,max=30:1')!;
    expect(fallback.tiers.single.confirm, isFalse);
    expect(fallback.tiers.single.maxMinutes, isNull);
    expect(ProfilePolicy.parse(' v=1 ; ; ')!.isEmpty, isTrue);
  });

  test('garbage is refused whole', () {
    for (final header in [
      '',
      'v=2;t=auto:1',
      't=auto:1;v=1',
      'v=1;v=1',
      'v=1;t=auto:1;t=fallback:1',
      'v=1;t=auto:1,1',
      'v=1;n=1:555;n=1:444',
      'v=1;n=1:556',
      'v=1;n=1:055',
      'v=1;n=1:55',
      'v=1;n=1:5555',
      'v=1;n=1',
      'v=1;n=1:555:a+b+c',
      'v=1;n=1:555:Bad',
      'v=1;n=1:555:a b',
      'v=1;n=1:555:x:y',
      'v=1;t=auto:',
      'v=1;t=auto:0',
      'v=1;t=auto:1000',
      'v=1;t=auto:01',
      'v=1;t=fast:1',
      'v=1;t=auto',
      'v=1;t=auto,:1',
      'v=1;t=last-resort,max=x:1',
      'v=1;t=auto:@',
      'v=1;t=auto:@a%2',
      'v=1;t=auto:@a b',
      'v=1;t=auto:@a%00b',
      'v=1;fail=2;fail=3',
      'v=1;fail=-1',
      'v=1;fail=02',
      'v=1;fail=two',
      'v=1;up=12345678',
      'v=1;=1',
      'v=1;garbage',
      'v=1;t=auto:1\x01',
      'v=1;n=1:555:ру',
      'v=1;t=auto:1;${List.filled(600, 'x=1').join(';')}',
      [for (var i = 1; i <= 9; i++) 't=auto:$i'].fold('v=1', (s, t) => '$s;$t'),
      'v=1;t=auto:${[for (var i = 1; i <= 33; i++) i].join(',')}',
      'v=1;${[for (var i = 1; i <= 65; i++) 'n=$i:333'].join(';')}',
    ]) {
      expect(ProfilePolicy.parse(header), isNull, reason: header);
    }
    expect(ProfilePolicy.parse('v=1;t=auto:${[for (var i = 1; i <= 32; i++) i].join(',')}'), isNotNull);
    expect(ProfilePolicy.parse(['v=1;t=auto:1', 'v=1;t=auto:2']), isNull, reason: 'two headers');
  });

  group('the subscription keeps it', () {
    test("only from the HTTP answer, canonical, with the time it came; never the server's own time", () {
      final headers = ProfileParser.populateHeaders(
        content: '#profile-policy: v=1;t=auto:9\nvless://x',
        remoteHeaders: {'profile-policy': samplePolicy, 'profile-policy-at': '1'},
      ).getOrElse((_) => throw StateError('no headers'));
      expect(headers['profile-policy'], sampleCanonical);
      final at = int.parse('${headers['profile-policy-at']}');
      expect(DateTime.now().millisecondsSinceEpoch ~/ 1000 - at, lessThan(5));
      final fromText = ProfileParser.populateHeaders(
        content: '#profile-policy: v=1;t=auto:9\nvless://x',
      ).getOrElse((_) => throw StateError('no headers'));
      expect(fromText.containsKey('profile-policy'), isFalse);
      final garbage = ProfileParser.populateHeaders(
        content: 'vless://x',
        remoteHeaders: {'profile-policy': 'v=1;t=auto:01'},
      ).getOrElse((_) => throw StateError('no headers'));
      expect(garbage.containsKey('profile-policy'), isFalse);
      expect(garbage.containsKey('profile-policy-at'), isFalse);
    });

    test('an update without it keeps it for its ttl; an empty one clears it', () {
      final at = DateTime(2026, 11, 2);
      final previous = {
        'profile-policy': sampleCanonical,
        'profile-policy-at': '${at.millisecondsSinceEpoch ~/ 1000}',
        'profile-title': 'x',
      };
      final kept = ProfileParser.keepPolicy(
        previous: previous,
        fresh: {'profile-title': 'y'},
        now: at.add(const Duration(days: 6)),
      );
      expect(kept['profile-policy'], sampleCanonical);
      expect(kept['profile-title'], 'y');
      final expired = ProfileParser.keepPolicy(
        previous: previous,
        fresh: {'profile-title': 'y'},
        now: at.add(const Duration(days: 8)),
      );
      expect(expired.containsKey('profile-policy'), isFalse);
      // the server's own ttl
      final short = {...previous, 'profile-policy': '$sampleCanonical;ttl=24'};
      expect(
        ProfileParser.keepPolicy(previous: short, fresh: {}, now: at.add(const Duration(hours: 25))),
        isNot(contains('profile-policy')),
      );
      // a new policy, or an empty one, replaces it at once
      final cleared = ProfileParser.keepPolicy(previous: previous, fresh: {'profile-policy': 'v=1'}, now: at);
      expect(cleared['profile-policy'], 'v=1');
      expect(ProfileParser.keepPolicy(previous: cleared, fresh: {}, now: at), isEmpty);
    });

    test("the core gets it as tier-policy, with the subscription's host and the probe's path", () {
      final headers = {'profile-policy': sampleCanonical, 'profile-probe': 'get=/files/sample.bin;size=131072'};
      final setting = ProfileParser.tierPolicySetting(headers, 'https://sub.example.net/path/token#name')!;
      expect(setting, {'policy': sampleCanonical, 'probe-host': 'sub.example.net', 'probe-path': '/files/sample.bin'});
      expect(ProfileParser.tierPolicySetting({'profile-policy': sampleCanonical}, 'https://sub.example.net/x'), {
        'policy': sampleCanonical,
        'probe-host': 'sub.example.net',
      });
      expect(ProfileParser.tierPolicySetting({'profile-policy': 'v=1'}, 'https://sub.example.net/x'), isNull);
      expect(ProfileParser.tierPolicySetting(headers, null), isNull, reason: 'a local profile');
      expect(ProfileParser.tierPolicySetting(headers, 'http://sub.example.net/x'), isNull);
      final override =
          jsonDecode(
                ProfileParser.profileOverride(
                  populatedHeaders: headers,
                  userOverride: null,
                  subscriptionUrl: 'https://sub.example.net/x',
                ),
              )
              as Map<String, dynamic>;
      expect((override['tier-policy'] as Map)['policy'], sampleCanonical);
      expect(override.containsKey('profile-policy'), isFalse);
      final none =
          jsonDecode(ProfileParser.profileOverride(populatedHeaders: {}, userOverride: null)) as Map<String, dynamic>;
      expect(none.containsKey('tier-policy'), isFalse);
    });
  });
}

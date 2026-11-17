import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/notification/in_app_notification_controller.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/model/profile_policy.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/features/proxy/tiers/tier_status.dart';
import 'package:hiddify/features/proxy/tiers/tier_widgets.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

// The server's rating in the app: what shows with a policy, and that nothing shows without one.
// Synthetic names and a made-up subscription host.

const _policy = 'v=1;n=2:545:main;n=9:335:udp;n=10:424:udp+ip-risk;t=auto:2,3;t=fallback:9;t=last-resort,confirm:10';

class _Profile extends ActiveProfile {
  _Profile(this.headers);
  final Map<String, dynamic>? headers;
  @override
  Stream<ProfileEntity?> build() => Stream.value(
    ProfileEntity.remote(
      id: 'p',
      active: true,
      name: 'p',
      url: 'https://sub.example.net/x',
      lastUpdate: DateTime(2026),
      populatedHeaders: headers,
    ),
  );
}

class _Main extends MainOutboundsNotifier {
  _Main(this.list);
  final OutboundGroupList list;
  @override
  Stream<OutboundGroupList> build() => Stream.value(list);
}

class _Toasts extends InAppNotificationController {
  final shown = <String>[];
  @override
  void showInfoToast(String message, {ToastAction? action}) => shown.add(message);
}

OutboundGroupList _mainList({required String picked, String? state}) => OutboundGroupList(
  items: [
    OutboundGroup(
      tag: 'select',
      selectable: true,
      selected: picked,
      items: [OutboundInfo(tag: picked, isGroup: picked == tieredGroupTag)],
    ),
    if (state != null)
      OutboundGroup(
        tag: tieredGroupTag,
        tierState: state,
        items: [OutboundInfo(tag: '9 India HTTP3')],
      ),
  ],
);

String _state(Map<String, Object> m) => jsonEncode(m);

Future<(Translations, _Toasts)> _pump(
  WidgetTester tester,
  Widget child, {
  AppLocale locale = AppLocale.ru,
  Map<String, dynamic>? headers,
  OutboundGroupList? main,
  double width = 420,
}) async {
  final toasts = _Toasts();
  // a locale other than English is a deferred library: loaded outside the test's fake time
  final t = (await tester.runAsync(() => locale.build()))!;
  final container = ProviderContainer(
    overrides: [
      translationsProvider.overrideWith((ref) => t),
      activeProfileProvider.overrideWith(() => _Profile(headers)),
      mainOutboundsNotifierProvider.overrideWith(() => _Main(main ?? OutboundGroupList())),
      inAppNotificationControllerProvider.overrideWithValue(toasts),
    ],
  );
  addTearDown(container.dispose);
  // a new tree for each container: a widget kept from the last one would watch the old container
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Center(child: SizedBox(width: width, child: child)),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return (t, toasts);
}

void main() {
  final policy = ProfilePolicy.parse(_policy)!;
  final places = policy.bind(['2 Bravo gRPC', '3 Charlie XHTTP', '9 India HTTP3', '10 Juliet WG', '5 Echo Naive']);

  testWidgets('a row shows the three scores in words, shorter on a narrow row', (tester) async {
    final (t, _) = await _pump(tester, TierRatingsLine(places['2 Bravo gRPC']!));
    expect(find.text('Надёжность 5 · Маскировка 4 · Безопасность 5'), findsOneWidget);
    await _pump(tester, TierRatingsLine(places['2 Bravo gRPC']!), width: 200);
    expect(find.text('Надёжн. 5 · Маскир. 4 · Безоп. 5'), findsOneWidget);
    expect(t.fork.tiers.reliability, 'Надёжность');
  });

  testWidgets('a reserve wears its chip, the last resort its own', (tester) async {
    final (t, _) = await _pump(tester, TierRatingsLine(places['9 India HTTP3']!), width: 600);
    expect(find.text(t.fork.tiers.reserveBadge), findsOneWidget);
    expect(find.text('Надёжность 3 · Маскировка 3 · Безопасность 5'), findsOneWidget);
    await _pump(tester, TierRatingsLine(places['10 Juliet WG']!), width: 600);
    expect(find.text(t.fork.tiers.lastResortBadge), findsOneWidget);
    // a recommended proxy has no chip
    await _pump(tester, TierRatingsLine(places['2 Bravo gRPC']!), width: 600);
    expect(find.text(t.fork.tiers.reserveBadge), findsNothing);
  });

  testWidgets('English too', (tester) async {
    await _pump(tester, TierRatingsLine(places['2 Bravo gRPC']!), locale: AppLocale.en);
    expect(find.text('Reliability 5 · Stealth 4 · Security 5'), findsOneWidget);
  });

  testWidgets('section titles over the reserves', (tester) async {
    final (t, _) = await _pump(
      tester,
      const Column(
        children: [
          TierSectionHeader(TierMode.auto),
          TierSectionHeader(TierMode.fallback),
          TierSectionHeader(TierMode.lastResort),
        ],
      ),
    );
    expect(find.text('Рекомендуемые'), findsOneWidget);
    expect(find.text('Резервные варианты'), findsOneWidget);
    expect(find.text('Последний резерв — используйте, только если остальное не работает'), findsOneWidget);
    expect(t.fork.tiers.other, 'Другие варианты');
  });

  testWidgets('the details: bars, captions, what the scale means', (tester) async {
    final (t, _) = await _pump(tester, SingleChildScrollView(child: TierDetails(places['10 Juliet WG']!)), width: 500);
    expect(find.byType(LinearProgressIndicator), findsNWidgets(3));
    expect(find.text(t.fork.tiers.outOf(n: 4)), findsNWidgets(2));
    expect(find.text(t.fork.tiers.captions.udp), findsOneWidget);
    expect(find.text(t.fork.tiers.captions.ipRisk), findsOneWidget);
    expect(find.text(t.fork.tiers.scaleHint), findsOneWidget);
    expect(find.text(t.fork.tiers.place.lastResort), findsOneWidget);
  });

  testWidgets('without a policy from the server, no scores and no marks at all', (tester) async {
    await _pump(tester, const TierDetailsOf('2 Bravo gRPC'));
    expect(find.byType(TierDetails), findsNothing);
    await _pump(tester, const TierDetailsOf('2 Bravo gRPC'), headers: {'profile-policy': _policy});
    expect(find.byType(TierDetails), findsOneWidget);
    // no tiered group, nothing on the home screen either
    await _pump(tester, const TierBanner(), main: _mainList(picked: 'lowest'));
    expect(find.byKey(const ValueKey('tier-banner')), findsNothing);
  });

  testWidgets('home: a reserve in use says which and why', (tester) async {
    final state = _state({'tier': 2, 'mode': 'fallback', 'node': '9 India HTTP3', 'reason': 'tcp-blocked', 'since': 1});
    final (t, toasts) = await _pump(tester, const TierBanner(), main: _mainList(picked: tieredGroupTag, state: state));
    expect(find.text(t.fork.tiers.banner.reserveTitle(name: '9 India HTTP3')), findsOneWidget);
    expect(find.text(t.fork.tiers.banner.tcpBlocked), findsOneWidget);
    expect(find.text(t.fork.tiers.banner.backUp), findsOneWidget);
    expect(toasts.shown, isEmpty);
  });

  testWidgets('home: the top tier working shows nothing', (tester) async {
    final state = _state({'tier': 0, 'mode': 'auto', 'node': '2 Bravo gRPC', 'reason': 'ok'});
    await _pump(tester, const TierBanner(), main: _mainList(picked: tieredGroupTag, state: state));
    expect(find.byKey(const ValueKey('tier-banner')), findsNothing);
  });

  testWidgets('home: the user picked another option, the state of the group shows nothing', (tester) async {
    final state = _state({'tier': 2, 'mode': 'fallback', 'node': '9 India HTTP3', 'reason': 'tcp-blocked'});
    await _pump(tester, const TierBanner(), main: _mainList(picked: '2 Bravo gRPC', state: state));
    expect(find.byKey(const ValueKey('tier-banner')), findsNothing);
  });

  testWidgets('home: the last resort waits for the user, with Use and Not now', (tester) async {
    final state = _state({'tier': 2, 'mode': 'last-resort', 'reason': 'confirm', 'confirm': '10 Juliet WG'});
    final (t, _) = await _pump(tester, const TierBanner(), main: _mainList(picked: tieredGroupTag, state: state));
    expect(find.text(t.fork.tiers.banner.confirmTitle), findsOneWidget);
    expect(find.text(t.fork.tiers.banner.confirmBody(name: '10 Juliet WG')), findsOneWidget);
    expect(find.text(t.fork.tiers.banner.use), findsOneWidget);
    await tester.tap(find.text(t.fork.tiers.banner.notNow));
    await tester.pump();
    expect(find.byKey(const ValueKey('tier-banner')), findsNothing);
  });

  testWidgets('home: the last resort in use, with a toast when it starts', (tester) async {
    final state = _state({'tier': 2, 'mode': 'last-resort', 'node': '10 Juliet WG', 'reason': 'tcp-blocked'});
    final (t, toasts) = await _pump(tester, const TierBanner(), main: _mainList(picked: tieredGroupTag, state: state));
    expect(find.text(t.fork.tiers.banner.lastResortTitle(name: '10 Juliet WG')), findsOneWidget);
    expect(find.text(t.fork.tiers.banner.lastResortHint), findsOneWidget);
    expect(toasts.shown, [t.fork.tiers.banner.toast(name: '10 Juliet WG')]);
  });

  test('the state of the core, and the sections of the list', () {
    expect(TierStatus.parse(''), isNull);
    expect(TierStatus.parse('{garbage'), isNull);
    final s = TierStatus.parse(
      '{"tier":3,"mode":"fallback","node":"9 x","reason":"tcp-blocked","down":["2 y",5],"network":"a1b2c3d4"}',
    )!;
    expect(s.onReserve, isTrue);
    expect(s.down, ['2 y']);
    expect(tierStatusOf(_mainList(picked: 'lowest', state: '{"reason":"ok"}')), isNull);
    final items = [
      OutboundInfo(tag: tieredGroupTag, isGroup: true),
      OutboundInfo(tag: '10 Juliet WG'),
      OutboundInfo(tag: '9 India HTTP3'),
      OutboundInfo(tag: '5 Echo Naive'),
      OutboundInfo(tag: '2 Bravo gRPC'),
    ];
    final sections = tierSections(items, places);
    expect(sections.map((s) => s.mode), [null, TierMode.auto, TierMode.fallback, TierMode.lastResort, TierMode.manual]);
    expect(sections[1].items.single.tag, '2 Bravo gRPC');
    expect(sections.last.items.single.tag, '5 Echo Naive');
  });
}

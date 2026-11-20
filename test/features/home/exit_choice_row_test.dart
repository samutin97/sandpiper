import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/features/home/widget/exit_choice_row.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/model/profile_exits.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/profile/notifier/exit_choice_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

String _b64(String text) => base64Url.encode(utf8.encode(text)).replaceAll('=', '');

RemoteProfileEntity _profile({String? header}) => RemoteProfileEntity(
  id: 'p1',
  active: true,
  name: 'subscription',
  url: 'https://example.org/sub/main-token',
  lastUpdate: DateTime(2026, 11, 20),
  populatedHeaders: {'profile-exits': ?header},
);

class _Active extends ActiveProfile {
  _Active(this.profile);
  final ProfileEntity? profile;

  @override
  Stream<ProfileEntity?> build() => Stream.value(profile);
}

class _Choice extends ExitChoiceNotifier {
  final chosen = <ExitRole>[];

  @override
  Future<void> choose(ProfileEntity profile, ExitRole target) async => chosen.add(target);
}

void main() {
  final pair = 'v=1;cur=main;alt=warp;alt-url=${_b64('https://example.org/sub/warp-token')}';

  Future<_Choice> pump(
    WidgetTester tester,
    ProfileEntity? profile, {
    AppLocale locale = AppLocale.ru,
    double width = 320,
  }) async {
    final t = (await tester.runAsync(() => locale.build()))!;
    final choice = _Choice();
    final container = ProviderContainer(
      overrides: [
        translationsProvider.overrideWith((ref) => t),
        activeProfileProvider.overrideWith(() => _Active(profile)),
        exitChoiceNotifierProvider.overrideWith(() => choice),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(width: width, child: const ExitChoiceRow()),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    return choice;
  }

  testWidgets('hidden while the server gave no pair', (tester) async {
    await pump(tester, _profile());
    expect(find.byKey(const ValueKey('exit_choice_row')), findsNothing);
    await pump(tester, _profile(header: 'v=2;cur=main'));
    expect(find.byKey(const ValueKey('exit_choice_row')), findsNothing);
    await pump(tester, null);
    expect(find.byKey(const ValueKey('exit_choice_row')), findsNothing);
  });

  testWidgets('shows both ways out in Russian, the main one chosen, with the one-line hint', (tester) async {
    await pump(tester, _profile(header: pair));
    expect(find.text('Выход в интернет'), findsOneWidget);
    expect(find.text('Основной'), findsOneWidget);
    expect(find.text('Cloudflare WARP'), findsOneWidget);
    expect(find.textContaining('если сайт не пускает с основного адреса'), findsOneWidget);
    expect(tester.widget<SegmentedButton<ExitRole>>(find.byType(SegmentedButton<ExitRole>)).selected, {ExitRole.main});
    expect(tester.takeException(), isNull, reason: 'it fits a narrow screen');
  });

  testWidgets('English too, and the other segment asks for the other way out', (tester) async {
    final choice = await pump(tester, _profile(header: pair), locale: AppLocale.en);
    expect(find.text('Way out to the internet'), findsOneWidget);
    expect(find.text('Main'), findsOneWidget);
    await tester.tap(find.text('Cloudflare WARP'));
    await tester.pump();
    expect(choice.chosen, [ExitRole.warp]);
    // the chosen one asks for nothing
    await tester.tap(find.text('Main'));
    await tester.pump();
    expect(choice.chosen, [ExitRole.warp]);
  });

  testWidgets('the pair of the other record shows warp chosen', (tester) async {
    final onWarp = 'v=1;cur=warp;alt=main;alt-url=${_b64('https://example.org/sub/main-token')}';
    await pump(tester, _profile(header: onWarp));
    expect(tester.widget<SegmentedButton<ExitRole>>(find.byType(SegmentedButton<ExitRole>)).selected, {ExitRole.warp});
  });
}

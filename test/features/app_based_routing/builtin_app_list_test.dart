import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/app_based_routing/data/auto_selection_repository.dart';

/// Item 8: the built-in list of Russian apps and how it becomes the apps kept out of the VPN.
void main() {
  test("upstream's pattern line ru.* takes no app: a pattern is not a package name", () {
    expect(expandAppList({'ru.*'}, {'ru.sberbankmobile', 'ru.rostel'}), isEmpty);
  });

  test('a prefix takes the installed apps that start with it, but no VPN client nor browser', () {
    final installed = {
      'ru.sberbankmobile',
      'ru.rostel',
      'ru.yandex.taxi',
      'com.yandex.browser',
      'ru.some.vpnclient',
      'ru.byedpi.app',
      'ru.tor.app',
      'org.telegram.messenger',
      'app.sandpiperbird.android',
    };
    final out = expandAppList({'prefix:ru.', 'prefix:com.yandex.'}, installed);
    expect(out, containsAll(['ru.sberbankmobile', 'ru.rostel', 'ru.yandex.taxi']));
    expect(out, isNot(contains('com.yandex.browser')));
    expect(out, isNot(contains('ru.some.vpnclient')));
    expect(out, isNot(contains('ru.byedpi.app')));
    expect(out, isNot(contains('ru.tor.app')));
    expect(out, isNot(contains('org.telegram.messenger')));
    expect(out, isNot(contains('app.sandpiperbird.android')));
  });

  test('names stay even when not installed (Android ignores them; they apply once installed)', () {
    expect(expandAppList({'com.docdoc.docdoc'}, {}), {'com.docdoc.docdoc'});
  });

  group('assets/app_lists/direct_ru.txt', () {
    final entries = AutoSelectionRepositoryImpl.parseAppList(File('assets/app_lists/direct_ru.txt').readAsStringSync());

    test("holds the apps found to look for VPNs, Gosuslugi and MAX among them", () {
      expect(
        entries,
        containsAll([
          'com.docdoc.docdoc',
          'ru.rostel',
          'ru.sberbankmobile',
          'com.idamob.tinkoff.android',
          'ru.ozon.app.android',
          'com.wildberries.ru',
          'ru.vk.store',
          'com.vkontakte.android',
          'ru.oneme.app',
          'ru.mts.mymts',
          'ru.beeline.services',
          'ru.tander.magnit',
        ]),
      );
    });

    test('starts with Gosuslugi and holds the apps with server-side VPN checks', () {
      final names = entries.where((e) => !e.startsWith('prefix:')).toList();
      // ru.rostel asks api.ipify.org for the external IP right after start
      expect(names.first, 'ru.rostel');
      // confirmed or server-side "VPN decisions"
      expect(
        names,
        containsAll([
          'ru.perekrestok.app',
          'ru.cian.main',
          'ru.hh.android',
          'ru.ivi.client',
          'com.avito.android',
          'ru.yandex.taxi',
          'com.punicapp.whoosh',
          'ru.dublgis.dgismobile',
        ]),
      );
    });

    test('is large enough, with the prefixes of Russian publishers', () {
      final names = entries.where((e) => !e.startsWith('prefix:'));
      expect(names.length, greaterThan(300));
      expect(entries, containsAll(['prefix:ru.', 'prefix:com.yandex.', 'prefix:com.vk.']));
    });

    test('names no VPN or proxy client', () {
      final bad = RegExp('vpn|proxy|xray|v2ray|amnezia|hiddify|byedpi|zapret|wireguard|clash', caseSensitive: false);
      expect(entries.where(bad.hasMatch), isEmpty);
    });

    test('has no patterns Android can not use', () {
      expect(entries.where((e) => e.contains('*')), isEmpty);
    });
  });
}

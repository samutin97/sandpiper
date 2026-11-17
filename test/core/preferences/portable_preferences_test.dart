import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/preferences/portable_preferences_store.dart';
import 'package:hiddify/core/preferences/session_proxy_secret.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

void main() {
  late Directory folder;

  setUp(() async {
    folder = await Directory.systemTemp.createTemp('portable-prefs-');
  });
  tearDown(() async {
    await folder.delete(recursive: true);
  });

  group('PortablePreferencesStore (W4-04)', () {
    test("keeps the portable build's settings in its own file", () async {
      final file = File('${folder.path}/sandpiper_portable_data/shared_preferences.json');
      final store = PortablePreferencesStore(file);
      SharedPreferencesStorePlatform.instance = store;
      SharedPreferences.resetStatic();
      SharedPreferences.setPrefix('portable.');
      addTearDown(() {
        SharedPreferences.resetStatic();
        SharedPreferences.setPrefix('flutter.');
      });
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString('lan_sharing_password', 'abcd-efgh-ijkl-mnop');
      await preferences.setInt('mixed-port', 41234);
      await preferences.setBool('allow-connection-from-lan', false);
      await preferences.setStringList('list', ['a', 'b']);

      final saved = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect(saved['portable.lan_sharing_password'], 'abcd-efgh-ijkl-mnop');
      expect(saved['portable.mixed-port'], 41234);

      // read back by a new store, as at the next launch
      final again = PortablePreferencesStore(file);
      final all = await again.getAllWithParameters(GetAllParameters(filter: PreferencesFilter(prefix: 'portable.')));
      expect(all['portable.mixed-port'], 41234);
      expect(all['portable.list'], ['a', 'b']);
      expect(all['portable.allow-connection-from-lan'], false);

      await again.remove('portable.mixed-port');
      await again.clearWithParameters(
        ClearParameters(filter: PreferencesFilter(prefix: 'portable.', allowList: {'portable.list'})),
      );
      final left = await PortablePreferencesStore(file).getAllWithPrefix('portable.');
      expect(left.keys, unorderedEquals(['portable.lan_sharing_password', 'portable.allow-connection-from-lan']));
    });

    test('moves what an earlier portable build left in the Roaming profile, once', () async {
      final roaming = File('${folder.path}/roaming/shared_preferences.json')..createSync(recursive: true);
      roaming.writeAsStringSync(
        jsonEncode({'portable.lan_sharing_password': 'old-secret', 'portable.mixed-port': 40000, 'flutter.theme': 'dark'}),
      );
      final file = File('${folder.path}/data/shared_preferences.json');
      final store = PortablePreferencesStore(file);
      expect(await store.moveFrom(roaming, 'portable.'), 2);
      expect((await store.getAllWithPrefix('portable.'))['portable.mixed-port'], 40000);
      // the installed app's settings stay, the portable ones are gone from the profile
      expect(jsonDecode(roaming.readAsStringSync()), {'flutter.theme': 'dark'});
      // not again once the portable file exists
      roaming.writeAsStringSync(jsonEncode({'portable.mixed-port': 1}));
      expect(await PortablePreferencesStore(file).moveFrom(roaming, 'portable.'), 0);
    });

    test('removes the Roaming file when only portable settings were in it', () async {
      final roaming = File('${folder.path}/roaming.json')..writeAsStringSync(jsonEncode({'portable.a': 'b'}));
      final store = PortablePreferencesStore(File('${folder.path}/data/shared_preferences.json'));
      expect(await store.moveFrom(roaming, 'portable.'), 1);
      expect(roaming.existsSync(), isFalse);
    });

    test('starts empty from an unreadable file', () async {
      final file = File('${folder.path}/shared_preferences.json')..writeAsStringSync('{not json');
      expect(await PortablePreferencesStore(file).getAllWithPrefix(''), isEmpty);
    });
  });

  group('renewSessionProxySecret (W4-04)', () {
    Future<SharedPreferences> preferencesWith(Map<String, Object> values) {
      SharedPreferences.resetStatic();
      SharedPreferences.setMockInitialValues(values);
      return SharedPreferences.getInstance();
    }

    test('a new password at every desktop launch', () async {
      final preferences = await preferencesWith({'lan_sharing_password': 'kept-from-last-time'});
      expect(await renewSessionProxySecret(preferences, desktop: true), isTrue);
      final first = preferences.getString('lan_sharing_password')!;
      expect(first, isNot('kept-from-last-time'));
      expect(first.replaceAll('-', '').length, greaterThanOrEqualTo(16));
      await renewSessionProxySecret(preferences, desktop: true);
      expect(preferences.getString('lan_sharing_password'), isNot(first));
    });

    test('kept when the user keeps it, while the proxy is shared on the network, and on phones', () async {
      for (final (values, desktop) in [
        ({'lan_sharing_password': 'mine', persistentProxySecretKey: true}, true),
        ({'lan_sharing_password': 'mine', 'allow-connection-from-lan': true}, true),
        ({'lan_sharing_password': 'mine'}, false),
      ]) {
        final preferences = await preferencesWith(values);
        expect(await renewSessionProxySecret(preferences, desktop: desktop), isFalse);
        expect(preferences.getString('lan_sharing_password'), 'mine');
      }
    });
  });
}

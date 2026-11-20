import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/directories/directories_provider.dart';
import 'package:hiddify/core/model/directories.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _main = 'https://example.org/sub/main-token';
const _warp = 'https://example.org/sub/warp-token';

String _b64(String text) => base64Url.encode(utf8.encode(text)).replaceAll('=', '');

class _Directories extends AppDirectories {
  _Directories(this.dir);

  final Directory dir;

  @override
  Future<Directories> build() async => (baseDir: dir, workingDir: dir, tempDir: dir);
}

RemoteProfileEntity _profile({String? header, String? exitUrl}) => RemoteProfileEntity(
  id: 'p1',
  active: true,
  name: 'subscription',
  url: _main,
  lastUpdate: DateTime(2026, 11, 20),
  populatedHeaders: {'profile-exits': ?header},
  userOverride: exitUrl == null ? null : UserOverride(exitUrl: exitUrl),
);

/// The settings the core is given for a profile are what the app's typed options make of the user's
/// own settings and the profile's override (ConnectionRepository.applyConfigOption, then
/// jsonEncode(options.toJson()) in the core service). A key the typed options do not have never
/// reaches the core: that was the break in 5.9.8-sp.14 (build 50926), where the journal had no exit.
void main() {
  late Directory dir;
  late ProviderContainer container;
  late ConfigOptionRepository repository;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('exit_to_core');
    SharedPreferences.setMockInitialValues({});
    container = ProviderContainer(overrides: [appDirectoriesProvider.overrideWith(() => _Directories(dir))]);
    await container.read(appDirectoriesProvider.future);
    final prefs = await container.read(sharedPreferencesProvider.future);
    repository = ConfigOptionRepository(
      preferences: prefs,
      getConfigOptions: () => container.read(ConfigOptions.singboxConfigOptions),
    );
  });

  tearDown(() async {
    container.dispose();
    await dir.delete(recursive: true);
  });

  /// The JSON the core service sends for [profile].
  Map<String, dynamic> sent(RemoteProfileEntity profile) {
    final options = repository.fullOptionsOverrided(profile.profileOverride()).getOrElse((f) => throw f);
    return jsonDecode(jsonEncode(options.toJson())) as Map<String, dynamic>;
  }

  test('a profile with a pair on the main one sends exit-choice main', () {
    final settings = sent(_profile(header: 'v=1;cur=main;alt=warp;alt-url=${_b64(_warp)}'));
    expect(settings['exit-choice'], 'main');
  });

  test('a profile on the other of the pair sends exit-choice warp', () {
    final settings = sent(_profile(header: 'v=1;cur=warp;alt=main;alt-url=${_b64(_main)}', exitUrl: _warp));
    expect(settings['exit-choice'], 'warp');
  });

  test('a profile without a pair sends no way out (null: the core leaves the field out)', () {
    expect(sent(_profile())['exit-choice'], isNull);
    expect(sent(_profile(header: 'v=2;cur=main'))['exit-choice'], isNull);
  });

  test('no link of the pair is among the settings', () {
    final text = jsonEncode(sent(_profile(header: 'v=1;cur=warp;alt=main;alt-url=${_b64(_main)}', exitUrl: _warp)));
    expect(text, isNot(contains('warp-token')));
    expect(text, isNot(contains('main-token')));
    expect(text, isNot(contains(_b64(_main))));
  });
}

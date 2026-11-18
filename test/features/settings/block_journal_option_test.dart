import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/directories/directories_provider.dart';
import 'package:hiddify/core/model/directories.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Directories extends AppDirectories {
  @override
  Future<Directories> build() async => (baseDir: Directory('.'), workingDir: Directory('.'), tempDir: Directory('.'));
}

void main() {
  Future<Map<String, dynamic>> settingsJson(Map<String, Object> stored) async {
    SharedPreferences.setMockInitialValues(stored);
    final container = ProviderContainer(overrides: [appDirectoriesProvider.overrideWith(_Directories.new)]);
    addTearDown(container.dispose);
    await container.read(appDirectoriesProvider.future);
    await container.read(sharedPreferencesProvider.future);
    return container.read(ConfigOptions.singboxConfigOptions).toJson();
  }

  test('the settings sent to the core carry block-journal: on by default', () async {
    expect((await settingsJson({}))['block-journal'], isTrue);
  });

  test('the settings sent to the core carry block-journal: false when the option is off', () async {
    expect((await settingsJson({'block-journal': false}))['block-journal'], isFalse);
  });
}

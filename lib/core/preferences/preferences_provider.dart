import 'dart:io';

import 'package:hiddify/core/directories/directories_provider.dart';
import 'package:hiddify/core/model/environment.dart';
import 'package:hiddify/core/preferences/portable_preferences_store.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:hiddify/utils/platform_utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

part 'preferences_provider.g.dart';

/// The portable build's settings file, beside its data (W4-04).
const portablePreferencesFile = 'shared_preferences.json';

@Riverpod(keepAlive: true)
Future<SharedPreferences> sharedPreferences(Ref ref) async {
  final logger = appLogger('preferences');
  SharedPreferences? sharedPreferences;
  final portable = await _usePortableStore(logger);

  logger.debug("initializing preferences");
  try {
    if (PlatformUtils.isWindows && Environment.isPortable) SharedPreferences.setPrefix('portable.');
    sharedPreferences = await SharedPreferences.getInstance();
  } catch (e) {
    logger.error("error initializing preferences", e);
    if (!Platform.isWindows && !Platform.isLinux) {
      rethrow;
    }
    // https://github.com/flutter/flutter/issues/89211
    final file = portable?.file ??
        File(p.join((await getApplicationSupportDirectory()).path, 'shared_preferences.json'));
    if (file.existsSync()) {
      file.deleteSync();
    }
  }

  return sharedPreferences ??= await SharedPreferences.getInstance();
}

/// The portable Windows build keeps its settings in its own folder, as its data, when it can write
/// there (else, as before, in the Roaming profile). Settings an earlier portable build left in the
/// Roaming profile are moved in, once.
Future<PortablePreferencesStore?> _usePortableStore(Logger logger) async {
  if (!PlatformUtils.isWindows || !Environment.isPortable) return null;
  final directory = AppDirectories.getPortableDirectory();
  if (!await AppDirectories.checkDirectoryAccess(directory)) return null;
  final store = PortablePreferencesStore(File(p.join(directory.path, portablePreferencesFile)));
  try {
    final roaming = File(p.join((await getApplicationSupportDirectory()).path, 'shared_preferences.json'));
    final moved = await store.moveFrom(roaming, 'portable.');
    if (moved > 0) logger.info("moved $moved portable settings out of the Roaming profile");
  } catch (e) {
    logger.warning("could not move the portable settings out of the Roaming profile", e);
  }
  SharedPreferencesStorePlatform.instance = store;
  return store;
}

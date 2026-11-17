import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

/// The folder of the app in the Roaming profile on Windows, as path_provider names it from the exe's
/// version resource: CompanyName, then ProductName (`windows/runner/Runner.rc`). shared_preferences
/// of an installed build keeps its settings there.
const windowsRoamingFolder = ['Sandpiper', 'sandpiper'];

/// W5-02: the shared_preferences.json an earlier portable build may have left in the Roaming profile,
/// found without making any folder: path_provider's getApplicationSupportDirectory creates the folder
/// on every call, and the portable build left an empty `%APPDATA%\Sandpiper\sandpiper` at every
/// launch. Null without APPDATA.
File? roamingPreferencesFile(Map<String, String> environment) {
  final appData = environment['APPDATA'];
  if (appData == null || appData.isEmpty) return null;
  return File(p.joinAll([appData, ...windowsRoamingFolder, 'shared_preferences.json']));
}

/// W5-02: removes the app's Roaming folders [roaming] sits in when they are empty (left by earlier
/// portable builds); a folder with anything in it, an installed build's, stays.
Future<void> removeEmptyRoamingFolders(File roaming) async {
  var folder = roaming.parent;
  for (var i = 0; i < windowsRoamingFolder.length; i++) {
    try {
      if (!folder.existsSync() || folder.listSync().isNotEmpty) return;
      await folder.delete();
    } on FileSystemException {
      return;
    }
    folder = folder.parent;
  }
}

/// The settings of the portable Windows build, in a file beside its data (`sandpiper_portable_data`).
///
/// shared_preferences_windows always writes to the user's Roaming profile (%APPDATA%): the portable
/// build left its settings there, the local proxy's password among them, on the computer it ran on, in
/// a folder Windows may copy to other computers, and lost them when its folder moved (W4-04).
class PortablePreferencesStore extends SharedPreferencesStorePlatform {
  PortablePreferencesStore(this.file);

  /// Where the settings are kept.
  final File file;

  Map<String, Object>? _cache;

  static const _defaultPrefix = 'flutter.';

  Map<String, Object> get _data => _cache ??= _read(file);

  static Map<String, Object> _read(File file) {
    try {
      if (!file.existsSync()) return {};
      final json = jsonDecode(file.readAsStringSync());
      if (json is! Map<String, dynamic>) return {};
      final data = <String, Object>{};
      json.forEach((key, value) {
        if (value is List) {
          data[key] = value.map((item) => '$item').toList();
        } else if (value is String || value is bool || value is num) {
          data[key] = value as Object;
        }
      });
      return data;
    } on Object {
      // unreadable or half written: the app starts with its defaults, as with a fresh folder
      return {};
    }
  }

  /// Written through a new file renamed over the old one: a crash never leaves half a file.
  Future<bool> _save() async {
    try {
      await file.parent.create(recursive: true);
      final next = File('${file.path}.new');
      await next.writeAsString(jsonEncode(_data), flush: true);
      await next.rename(file.path);
      return true;
    } on FileSystemException {
      return false;
    }
  }

  static bool _matches(String key, PreferencesFilter filter) =>
      key.startsWith(filter.prefix) && (filter.allowList == null || filter.allowList!.contains(key));

  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    _data[key] = value;
    return _save();
  }

  @override
  Future<bool> remove(String key) {
    _data.remove(key);
    return _save();
  }

  @override
  Future<bool> clear() => clearWithParameters(ClearParameters(filter: PreferencesFilter(prefix: _defaultPrefix)));

  @override
  Future<bool> clearWithPrefix(String prefix) =>
      clearWithParameters(ClearParameters(filter: PreferencesFilter(prefix: prefix)));

  @override
  Future<bool> clearWithParameters(ClearParameters parameters) {
    _data.removeWhere((key, _) => _matches(key, parameters.filter));
    return _save();
  }

  @override
  Future<Map<String, Object>> getAll() =>
      getAllWithParameters(GetAllParameters(filter: PreferencesFilter(prefix: _defaultPrefix)));

  @override
  Future<Map<String, Object>> getAllWithPrefix(String prefix) =>
      getAllWithParameters(GetAllParameters(filter: PreferencesFilter(prefix: prefix)));

  @override
  Future<Map<String, Object>> getAllWithParameters(GetAllParameters parameters) async {
    return Map<String, Object>.from(_data)..removeWhere((key, _) => !_matches(key, parameters.filter));
  }

  /// Moves the settings with [prefix] an earlier portable build left in [roaming] (the Roaming
  /// profile's shared_preferences.json) into this store, once: only while this store has no file yet.
  /// They are removed from [roaming]; the file goes when nothing else is left in it. Returns how many
  /// were moved.
  Future<int> moveFrom(File roaming, String prefix) async {
    if (file.existsSync() || !roaming.existsSync()) return 0;
    final old = _read(roaming);
    final moved = Map<String, Object>.from(old)..removeWhere((key, _) => !key.startsWith(prefix));
    if (moved.isEmpty) return 0;
    _data.addAll(moved);
    if (!await _save()) return 0;
    old.removeWhere((key, _) => key.startsWith(prefix));
    try {
      if (old.isEmpty) {
        await roaming.delete();
      } else {
        final next = File('${roaming.path}.new');
        await next.writeAsString(jsonEncode(old), flush: true);
        await next.rename(roaming.path);
      }
    } on FileSystemException {
      // kept there: the password among them is made anew at the next launch anyway
    }
    return moved.length;
  }
}

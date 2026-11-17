import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:hiddify/core/model/directories.dart';
import 'package:hiddify/core/model/environment.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:hiddify/utils/platform_utils.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'directories_provider.g.dart';

@Riverpod(keepAlive: true)
class AppDirectories extends _$AppDirectories with InfraLogger {
  final _methodChannel = const MethodChannel("com.hiddify.app/platform");

  @override
  Future<Directories> build() async {
    final Directories dirs;
    if (kIsWeb) {
      return (baseDir: Directory("."), workingDir: Directory("."), tempDir: Directory("."));
    }
    if (PlatformUtils.isIOS) {
      final paths = await _methodChannel.invokeMethod<Map>("get_paths");
      loggy.debug("paths: $paths");
      dirs = (
        baseDir: Directory(paths?["base"]! as String),
        workingDir: Directory(paths?["working"]! as String),
        tempDir: Directory(paths?["temp"]! as String),
      );
    } else if (PlatformUtils.isWindows &&
        Environment.isPortable &&
        await checkDirectoryAccess(getPortableDirectory())) {
      final portableDir = getPortableDirectory();
      dirs = (baseDir: portableDir, workingDir: portableDir, tempDir: await getTemporaryDirectory());
    } else {
      final baseDir = await getApplicationSupportDirectory();
      final workingDir = Platform.isAndroid ? await _getAndroidWorkingDirectory(baseDir) : baseDir;
      final tempDir = await getTemporaryDirectory();
      dirs = (baseDir: baseDir, workingDir: workingDir, tempDir: tempDir);
    }

    if (!dirs.baseDir.existsSync()) {
      await dirs.baseDir.create(recursive: true);
    }
    if (!dirs.workingDir.existsSync()) {
      await dirs.workingDir.create(recursive: true);
    }

    return dirs;
  }

  /// H-05: on Android the core's working directory (profile configs, the core's database and logs,
  /// crash reports) is in the app's private storage (`files/working`, 0700, files 0600 by the app's
  /// umask), never on shared storage: `Android/data/<package>/files` is readable over USB/MTP and
  /// adb, by apps with storage access on Android 7-10, and went into backups.
  static Future<Directory> _getAndroidWorkingDirectory(Directory baseDir) async {
    final working = Directory(p.join(baseDir.path, 'working'));
    if (!working.existsSync()) await working.create(recursive: true);
    await _leaveExternalStorage(working);
    return working;
  }

  /// Once: moves the profile configs an older build kept on external storage into [working] and
  /// deletes everything that was there (configs, logs, current-config.json, crash reports). A new
  /// install has nothing there; any failure is ignored, the app works without it.
  static Future<void> _leaveExternalStorage(Directory working) async {
    final marker = File(p.join(working.path, '.external-storage-checked'));
    if (marker.existsSync()) return;
    try {
      final external = await getExternalStorageDirectory();
      if (external != null && external.existsSync()) {
        final oldConfigs = Directory(p.join(external.path, 'configs'));
        final newConfigs = Directory(p.join(working.path, 'configs'));
        if (oldConfigs.existsSync() && !newConfigs.existsSync()) {
          await newConfigs.create(recursive: true);
          for (final file in oldConfigs.listSync().whereType<File>()) {
            await file.copy(p.join(newConfigs.path, p.basename(file.path)));
          }
        }
        for (final entry in external.listSync()) {
          try {
            await entry.delete(recursive: true);
          } catch (_) {}
        }
      }
    } catch (_) {}
    try {
      await marker.create();
    } catch (_) {}
  }

  static Future<Directory> getDatabaseDirectory() async {
    if (kIsWeb) {
      return Directory(".");
    }
    if (PlatformUtils.isIOS || PlatformUtils.isMacOS) {
      return await getLibraryDirectory();
    } else if (PlatformUtils.isWindows &&
        Environment.isPortable &&
        await checkDirectoryAccess(getPortableDirectory())) {
      final portableDir = getPortableDirectory();
      return portableDir;
    } else if (PlatformUtils.isWindows || PlatformUtils.isLinux) {
      return await getApplicationSupportDirectory();
    }
    return await getApplicationDocumentsDirectory();
  }

  static Directory getPortableDirectory() {
    final exeDir = File(Platform.resolvedExecutable).parent;
    return Directory(p.join(exeDir.path, 'hiddify_portable_data'));
  }

  static Future<bool> checkDirectoryAccess(Directory dir) async {
    final testFile = File(p.join(dir.path, 'access_test.txt'));

    try {
      if (!await dir.exists()) await dir.create(recursive: true);
      await testFile.writeAsString('Testing write permission...');
      await testFile.readAsString();
      await testFile.delete();
      return true;
    } catch (_) {
      return false;
    }
  }
}

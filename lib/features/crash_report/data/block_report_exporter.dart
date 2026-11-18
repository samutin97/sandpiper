import 'dart:io';

import 'package:grpc/grpc.dart';
import 'package:hiddify/core/directories/directories_provider.dart';
import 'package:hiddify/features/log/data/log_data_providers.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service_provider.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path/path.dart' as p;

final _log = appLogger('BlockReport');

/// The same limits as the diagnostics report: the core takes a request under its 4 MB receive limit.
const _maxRequestSize = 3584 * 1024;
const _maxAppLogFileSize = 256 * 1024;
const _maxServiceZipSize = 2 << 20;

final blockReportExporterProvider = Provider<BlockReportExporter>(BlockReportExporter.new);

/// Builds the zip for a report of a block: the core zips its connection journal (never the sites the
/// user visits), its summary and its scrubbed log, and the app adds the tail of its own log. When
/// the background core is another process (the Windows tunnel service, macOS) it has its own
/// journal, which comes along as `service-core.zip`.
class BlockReportExporter {
  BlockReportExporter(this._ref);

  final Ref _ref;

  /// On Android both channels reach one core in one process, which has one journal; elsewhere the
  /// background core is another process with its own working directory.
  bool get _separateBackground {
    final core = _ref.read(hiddifyCoreServiceProvider).core;
    return !core.isSingleChannel() && !core.coreSharesProcess;
  }

  Future<File> export() async {
    final core = _ref.read(hiddifyCoreServiceProvider).core;
    final extraFiles = <String, List<int>>{};

    final appLog = _ref.read(logPathResolverProvider).appFile();
    try {
      if (appLog.existsSync()) extraFiles['app.log'] = await _readTail(appLog, _maxAppLogFileSize);
    } catch (e) {
      _log.info('the app log file could not be read: $e');
    }

    if (_separateBackground) {
      // the service may not run at all: a few seconds, then go on without it
      try {
        final response = await core.bgClient.blockJournal(
          BlockJournalRequest(export: true, inline: true),
          options: CallOptions(timeout: const Duration(seconds: 5)),
        );
        final room = _maxRequestSize - extraFiles.values.fold(0, (sum, content) => sum + content.length);
        if (response.content.length <= _maxServiceZipSize && response.content.length <= room) {
          extraFiles['service-core.zip'] = response.content;
        } else {
          _log.info('the service core zip is too large to include: ${response.content.length} bytes');
        }
      } catch (e) {
        _log.info('no journal from the background core: $e');
      }
    }

    final response = await core.fgClient.blockJournal(
      BlockJournalRequest(export: true, inline: true, extraFiles: extraFiles),
    );
    if (response.content.isEmpty) throw StateError('the core returned an empty block report');

    // a neutral name: the file goes to people the user chooses, and names nothing of the app
    final dir = _ref.read(appDirectoriesProvider).requireValue.tempDir;
    // the reports made before were saved or shared then: they hold the servers' addresses and are
    // not kept here
    try {
      for (final old in dir.listSync().whereType<File>()) {
        final name = p.basename(old.path);
        if (name.startsWith('net-report-') && name.endsWith('.zip')) old.deleteSync();
      }
    } catch (e) {
      _log.info('an earlier block report could not be removed: $e');
    }
    final file = File(p.join(dir.path, 'net-report-${_stamp(DateTime.now().toUtc())}.zip'));
    await file.writeAsBytes(response.content, flush: true);
    _log.info('block report written: ${response.content.length} bytes');
    return file;
  }

  /// Deletes the journal of the core, and of the background core when it is another process.
  Future<void> clear() async {
    final core = _ref.read(hiddifyCoreServiceProvider).core;
    if (_separateBackground) {
      try {
        await core.bgClient.blockJournal(
          BlockJournalRequest(clear_1: true),
          options: CallOptions(timeout: const Duration(seconds: 5)),
        );
      } catch (e) {
        _log.info('the background core journal was not cleared: $e');
      }
    }
    await core.fgClient.blockJournal(BlockJournalRequest(clear_1: true));
  }

  /// Bytes the journal holds, of both cores when they are separate.
  Future<int> size() async {
    final core = _ref.read(hiddifyCoreServiceProvider).core;
    var total = 0;
    if (_separateBackground) {
      try {
        final response = await core.bgClient.blockJournal(
          BlockJournalRequest(),
          options: CallOptions(timeout: const Duration(seconds: 5)),
        );
        total += response.size.toInt();
      } catch (e) {
        _log.info('the background core journal size is unknown: $e');
      }
    }
    final response = await core.fgClient.blockJournal(BlockJournalRequest());
    return total + response.size.toInt();
  }

  /// The newest [max] bytes: the end of a log is what led up to the problem.
  static Future<List<int>> _readTail(File file, int max) async {
    final length = await file.length();
    if (length <= max) return file.readAsBytes();
    final handle = await file.open();
    try {
      await handle.setPosition(length - max);
      return await handle.read(max);
    } finally {
      await handle.close();
    }
  }

  static String _stamp(DateTime utc) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${utc.year.toString().padLeft(4, '0')}-${two(utc.month)}-${two(utc.day)}T${two(utc.hour)}-${two(utc.minute)}-${two(utc.second)}';
  }
}

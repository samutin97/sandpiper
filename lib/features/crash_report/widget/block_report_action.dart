import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/notification/in_app_notification_controller.dart';
import 'package:hiddify/features/crash_report/data/block_report_exporter.dart';
import 'package:hiddify/features/log/overview/logs_modals.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

final _log = appLogger('BlockReport');

/// Makes the report and offers it: a save dialog on desktop, the share sheet on a phone. Shared by
/// the settings page and the logs sheet. Failures are a toast and a log line, never thrown.
Future<void> collectAndSaveBlockReport(WidgetRef ref) async {
  // everything is read before the first await: the sheet that asked for the report is gone by the
  // time it is made, and a disposed widget's ref cannot be used
  final t = ref.read(translationsProvider).requireValue;
  final notifications = ref.read(inAppNotificationControllerProvider);
  final exporter = ref.read(blockReportExporterProvider);
  try {
    notifications.showInfoToast(t.pages.settings.general.blockReport.collecting);
    final file = await exporter.export();
    await saveFileAs(file, t: t, notifications: notifications);
  } catch (e, stack) {
    // the error goes to the log only: its text may hold a path with the user's name
    _log.error('collecting the block report failed', e, stack);
    notifications.showErrorToast(t.pages.settings.general.blockReport.failed);
  }
}

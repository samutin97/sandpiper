import 'package:hiddify/features/crash_report/data/diagnostics_exporter.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

final diagnosticsSenderProvider = Provider<DiagnosticsSender>((ref) => const DiagnosticsSender());

/// Upstream uploads reports to the developers' Sentry. The fork sends nothing anywhere: a report is
/// only saved or shared by the user (ReportChannel.local).
class DiagnosticsSender {
  const DiagnosticsSender();

  static bool get available => false;

  Future<bool> send(DiagnosticsReport report, {String? crashName, String? description, String? crashText}) async =>
      false;
}

import 'package:flutter/material.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/core/router/bottom_sheets/widgets/quick_settings_modal.dart';
import 'package:hiddify/core/router/go_router/go_router_notifier.dart';
import 'package:hiddify/features/app_based_routing/model/app_package_info.dart';
import 'package:hiddify/features/app_based_routing/overview/app_list_share_modal.dart';
import 'package:hiddify/features/connection/widget/connection_health_sheet.dart';
import 'package:hiddify/features/log/overview/logs_modals.dart';
import 'package:hiddify/features/profile/add/add_profile_modal.dart';
import 'package:hiddify/features/profile/add/import_preview.dart';
import 'package:hiddify/features/profile/overview/profiles_modal.dart';

import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'bottom_sheets_notifier.g.dart';

@riverpod
class BottomSheetsNotifier extends _$BottomSheetsNotifier {
  @override
  void build() {}

  Future<T?> _show<T>({required Widget child, required bool isScrollControlled}) async {
    final context = rootNavKey.currentContext;
    if (context == null) return null;
    // ref.read(popupCountNotifierProvider.notifier).increase();
    // showModalBottomSheet also gives the dimmed layer behind the sheet its screen reader label and hint
    return await showModalBottomSheet<T>(
      context: context,
      useRootNavigator: true,
      constraints: BottomSheetConst.boxConstraints,
      isScrollControlled: isScrollControlled,
      builder: (context) => ClipRRect(
        borderRadius: BottomSheetConst.borderRadius,
        child: Material(
          child: Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
            child: child,
          ),
        ),
      ),
    ).then((value) {
      // ref.read(popupCountNotifierProvider.notifier).decrease();
      return value;
    });
  }

  /// Opens the add-profile sheet; with [url] (a deep link, or text pasted by the paste shortcut) it
  /// imports that, after the import dialog shows what it is and where it comes from (H-04). Nothing
  /// is downloaded before the user agrees.
  Future<void> showAddProfile({String? url, bool triggeredByDeepLink = false}) async {
    await _show(
      isScrollControlled: true,
      child: AddProfileModal(url: url, source: triggeredByDeepLink ? ImportSource.deepLink : ImportSource.clipboard),
    );
  }

  Future<void> showProfilesOverview() async => await _show(isScrollControlled: true, child: const ProfilesModal());

  Future<void> showQuickSettings() async => await _show(isScrollControlled: false, child: const QuickSettingsModal());

  Future<void> showLogsShare() async => await _show(isScrollControlled: false, child: const LogsShareModal());

  Future<void> showLogsRecent() async => await _show(isScrollControlled: false, child: const LogsRecentModal());

  Future<void> showConnectionHealth() async =>
      await _show(isScrollControlled: true, child: const ConnectionHealthSheet());

  Future<void> showAppListShare({
    required List<String> added,
    required List<String> removed,
    required Map<String, AppPackageInfo> apps,
  }) async => await _show(
    isScrollControlled: true,
    child: AppListShareModal(added: added, removed: removed, apps: apps),
  );
}

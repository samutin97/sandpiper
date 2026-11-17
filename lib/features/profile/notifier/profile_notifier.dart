import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hiddify/core/haptic/haptic_service.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/failures.dart';
import 'package:hiddify/core/notification/in_app_notification_controller.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/profile/add/import_preview.dart';
import 'package:hiddify/features/profile/add/model/free_profiles_model.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/data/profile_repository.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/model/profile_failure.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/profile/notifier/tunnel_guard.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/utils/riverpod_utils.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'profile_notifier.g.dart';

@riverpod
class AddProfileNotifier extends _$AddProfileNotifier with AppLogger {
  @override
  AsyncValue<Unit?> build() {
    ref.disposeDelay(const Duration(minutes: 1));
    ref.onDispose(() {
      loggy.debug("disposing");
      _cancelToken?.cancel();
    });
    listenSelf((previous, next) {
      final t = ref.read(translationsProvider).requireValue;
      final notification = ref.read(inAppNotificationControllerProvider);
      switch (next) {
        case AsyncData(value: final _?):
          notification.showSuccessToast(lastImportActivated ? t.pages.profiles.msg.save.success : t.fork.import.added);
        case AsyncError(:final error):
          if (error case ProfileInvalidUrlFailure(:final message?) when message.contains('https')) {
            notification.showErrorToast(t.fork.import.insecureHttp);
          } else if (error case ProfileInvalidUrlFailure()) {
            notification.showErrorToast(t.pages.profiles.msg.invalidUrl);
          } else if (error case ProfileCancelByUserFailure()) {
            return;
          } else {
            ref
                .read(dialogNotifierProvider.notifier)
                .showCustomAlertFromErr(t.presentError(error, action: t.pages.profiles.msg.add.failure));
          }
      }
    });
    ref.onDispose(() {
      if (!(_cancelToken?.isCancelled ?? true)) _cancelToken?.cancel();
    });
    return const AsyncData(null);
  }

  ProfileRepository get _profilesRepo => ref.read(profileRepositoryProvider).requireValue;
  CancelToken? _cancelToken;

  /// Whether the last import selected the new profile (there was no profile selected before).
  bool lastImportActivated = true;

  /// Imports [rawInput] (a subscription link, links, or a config) from [source] (H-04): first a dialog
  /// shows what it is and where it comes from, and nothing is downloaded before the user agrees. The
  /// new profile is selected only when no profile is: an import never switches, nor reconnects, a
  /// running tunnel. Subscriptions over http:// are refused.
  Future<void> addClipboard(String rawInput, {required ImportSource source}) async {
    if (state.isLoading) return;
    final preview = previewImport(rawInput);
    final t = ref.read(translationsProvider).requireValue;
    final dialogs = ref.read(dialogNotifierProvider.notifier);
    if (preview.refusal == ImportRefusal.insecureHttp) {
      await dialogs.showCustomAlert(title: t.fork.import.refusedTitle, message: t.fork.import.insecureHttp);
      return;
    }
    final activate = await ref.read(activeProfileProvider.future) == null;
    final tunneled = await appTrafficTunneledNow(ref);
    final confirmed = await dialogs.showConfirmation(
      title: t.fork.import.title,
      message: importDialogMessage(t, preview, source, activate: activate, tunneled: tunneled),
      positiveBtnTxt: t.fork.import.confirm,
    );
    if (!confirmed) return;
    lastImportActivated = activate;
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final TaskEither<ProfileFailure, Unit> task;
      if (LinkParser.parse(rawInput) case (final rs)?) {
        loggy.debug("adding remote profile");
        task = _profilesRepo.upsertRemote(
          rs.url,
          userOverride: rs.name.isNotEmpty ? UserOverride(name: rs.name) : null,
          cancelToken: _cancelToken = CancelToken(),
          activate: activate,
        );
      } else {
        loggy.debug("adding profile, content");
        task = _profilesRepo.addLocal(safeDecodeBase64(rawInput), activate: activate).map((_) => unit);
      }
      return await task
          .match(
            (err) {
              loggy.warning("failed to add profile", err);
              throw err;
            },
            (_) {
              loggy.info("successfully added profile");
              return unit;
            },
          )
          .run();
    });
  }

  /// The import dialog's text: where the profile comes from, its name, its subscription or servers,
  /// and what importing it does.
  static String importDialogMessage(
    Translations t,
    ImportPreview preview,
    ImportSource source, {
    required bool activate,
    required bool tunneled,
  }) {
    final lines = <String>[
      t.fork.import.from(
        source: switch (source) {
          ImportSource.deepLink => t.fork.import.source.deepLink,
          ImportSource.clipboard => t.fork.import.source.clipboard,
          ImportSource.file => t.fork.import.source.file,
          ImportSource.qrCode => t.fork.import.source.qrCode,
          ImportSource.phone => t.fork.import.source.phone,
        },
      ),
      if (preview.type case final type?) t.fork.import.type(type: type),
      if (preview.name.isNotEmpty) t.fork.import.name(name: preview.name),
      if (preview.remote) t.fork.import.subscription(url: 'https://${preview.host ?? ''}'),
      if (!preview.remote && preview.servers.isNotEmpty)
        t.fork.import.servers(
          list: [
            ...preview.servers,
            if (preview.serverCount > preview.servers.length)
              t.fork.import.more(n: preview.serverCount - preview.servers.length),
          ].join(', '),
        ),
      '',
      if (activate) t.fork.import.firstActivated else t.fork.import.notActivated,
      // SP3-05: how the subscription is downloaded, either way
      if (preview.remote) tunneled ? t.fork.import.tunneled : t.fork.import.direct(host: preview.host ?? ''),
    ];
    return lines.join('\n');
  }

  /// Adds all the files of a zip as one profile named [name]. The files are merged into one text that goes straight to
  /// the core, which decides which of them are valid configs.
  Future<void> addArchive(Uint8List zipBytes, {required String name}) async {
    if (state.isLoading) return;
    final text = readZipText(zipBytes);
    final t = ref.read(translationsProvider).requireValue;
    final activate = await ref.read(activeProfileProvider.future) == null;
    if (text.isNotEmpty) {
      final preview = previewImport(text);
      final confirmed = await ref
          .read(dialogNotifierProvider.notifier)
          .showConfirmation(
            title: t.fork.import.title,
            message: importDialogMessage(
              t,
              ImportPreview(name: name, remote: false, servers: preview.servers, serverCount: preview.serverCount),
              ImportSource.file,
              activate: activate,
              tunneled: true,
            ),
            positiveBtnTxt: t.fork.import.confirm,
          );
      if (!confirmed) return;
    }
    lastImportActivated = activate;
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      if (text.isEmpty) throw const ProfileFailure.invalidConfig();
      return await _profilesRepo
          .addLocal(text, userOverride: UserOverride(name: name), activate: activate)
          .match(
            (err) {
              loggy.warning("failed to add profile from zip", err);
              throw err;
            },
            (_) {
              loggy.info("successfully added profile from zip");
              return unit;
            },
          )
          .run();
    });
  }

  /// A subscription the user typed in the app: selected right away, as before (no other app can do
  /// this). Only https: the parser refuses http.
  Future<void> addManual({required String url, required UserOverride userOverride}) async {
    if (state.isLoading) return;
    lastImportActivated = true;
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final task = _profilesRepo.upsertRemote(url, userOverride: userOverride, activate: true);
      return await task
          .match(
            (err) {
              loggy.warning("failed to add profile", err);
              throw err;
            },
            (r) {
              loggy.info("successfully added profile, mark as active? [true]");
              return r;
            },
          )
          .run();
    });
  }
}

@riverpod
class UpdateProfileNotifier extends _$UpdateProfileNotifier with AppLogger {
  Timer? _resetTimer;

  @override
  AsyncValue<Unit?> build(String id) {
    ref.disposeDelay(const Duration(minutes: 1));
    ref.onDispose(() => _resetTimer?.cancel());
    return const AsyncData(null);
  }

  ProfileRepository get _profilesRepo => ref.read(profileRepositoryProvider).requireValue;

  Future<void> updateProfile(RemoteProfileEntity profile, {bool isBulk = false}) async {
    if (state.isLoading) return;
    // an update by hand asks before it goes around the tunnel; a bulk run checked already (H-02)
    if (!isBulk && !await confirmRequestOutsideTunnel(ref)) return;
    _resetTimer?.cancel();
    state = const AsyncLoading();
    if (!isBulk) await ref.read(hapticServiceProvider.notifier).lightImpact();
    state = await AsyncValue.guard(() async {
      return await _profilesRepo
          .upsertRemote(profile.url)
          .match(
            (err) {
              loggy.warning("failed to update profile", err);
              throw err;
            },
            (_) async {
              loggy.info('successfully updated profile');

              await ref.read(activeProfileProvider.future).then((active) async {
                if (active != null && active.id == profile.id) {
                  await ref.read(connectionNotifierProvider.notifier).reconnect(profile);
                }
              });
              return unit;
            },
          )
          .run();
    });

    // Single, user-initiated updates report failure via a dialog; success is
    // shown inline by the button indicator. Bulk runs stay silent here and are
    // summarized in one aggregate toast by ForegroundProfilesUpdateNotifier.
    if (state case AsyncError(:final error) when !isBulk) {
      final t = ref.read(translationsProvider).requireValue;
      ref
          .read(dialogNotifierProvider.notifier)
          .showCustomAlertFromErr(t.presentError(error, action: t.pages.profiles.msg.update.failure));
    }

    // Hold the success/failure result for 2s so the leading can flash an icon,
    // then reset to idle. Kept in the provider (not widget state) so it survives
    // the profile list re-sorting that happens right after an update.
    _resetTimer?.cancel();
    _resetTimer = Timer(const Duration(seconds: 2), () => state = const AsyncData(null));
  }
}

@riverpod
class FreeSwitchNotifier extends _$FreeSwitchNotifier {
  @override
  bool build() {
    return false;
  }

  Future<void> onChange(bool value) async => state = value;
}

@riverpod
class AddProfilePageNotifier extends _$AddProfilePageNotifier {
  @override
  AddProfilePages build() => AddProfilePages.options;

  void goOptions() => state = AddProfilePages.options;
  void goManual() => state = AddProfilePages.manual;
}

enum AddProfilePages { options, manual }

@riverpod
class FreeProfilesNotifier extends _$FreeProfilesNotifier {
  @override
  // the fork offers no free profiles: nothing is downloaded from Hiddify's repository
  Future<List<FreeProfile>> build() async => const <FreeProfile>[];
}

@riverpod
Future<List<FreeProfile>> freeProfilesFilteredByRegion(Ref ref) async {
  final freeProfiles = await ref.watch(freeProfilesNotifierProvider.future);
  final region = ref.watch(ConfigOptions.region);
  return freeProfiles.where((e) => e.region.contains(region.name) || e.region.isEmpty).toList();
}

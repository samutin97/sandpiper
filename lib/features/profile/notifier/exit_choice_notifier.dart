import 'package:dio/dio.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hiddify/core/haptic/haptic_service.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/notification/in_app_notification_controller.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/model/profile_exits.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/profile/notifier/tunnel_guard.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'exit_choice_notifier.g.dart';

/// The way out to the internet of a profile whose server offers a pair of them (`profile-exits`,
/// see profile_exits.dart): what the choice is, and what taking it does. Pure, so a test needs no
/// network.
abstract final class ExitChoice {
  /// Whether [profile] has a choice to show: a remote profile whose server sent a valid pair.
  static bool offered(ProfileEntity? profile) => profile is RemoteProfileEntity && profile.exits != null;

  /// The way out [profile] is on: what its subscription says it is.
  static ExitRole? current(ProfileEntity? profile) => offered(profile) ? profile!.exits!.current : null;

  /// The user's choices of [profile] once it is on [target], or null when there is nothing to do
  /// (no pair, or already there). From the profile's own link the way is the pair's link; from the
  /// pair's, back to the profile's own, which an older version knows and goes on with.
  static UserOverride? overrideFor(ProfileEntity profile, ExitRole target) {
    if (profile is! RemoteProfileEntity) return null;
    final exits = profile.exits;
    if (exits == null || exits.current == target || exits.alternative != target) return null;
    final override = profile.userOverride ?? const UserOverride();
    return override.exitUrl != null
        ? override.copyWith(exitUrl: null)
        : override.copyWith(exitUrl: exits.alternativeUrl);
  }

  /// Whether an update took the profile back to its own link: it was on the pair's, and is not.
  static bool fellBack(ProfileEntity before, ProfileEntity? after) =>
      before.userOverride?.exitUrl != null && after != null && after.userOverride?.exitUrl == null;
}

/// Takes the other way out: the pair's subscription becomes the profile's, and the connection, if
/// there is one, is made again with it. Nothing is stored unless that subscription loads and is the
/// one asked for, so a failure leaves the way out and the connection as they were.
@riverpod
class ExitChoiceNotifier extends _$ExitChoiceNotifier with AppLogger {
  @override
  AsyncValue<Unit?> build() => const AsyncData(null);

  /// The user's choice: asks first when the download would go around the tunnel, as any update by hand.
  Future<void> choose(ProfileEntity profile, ExitRole target) async {
    if (state.isLoading || ExitChoice.overrideFor(profile, target) == null) return;
    if (!await confirmRequestOutsideTunnel(ref)) return;
    await apply(profile, target);
  }

  /// Takes [target] now: the subscription is downloaded, and only when it is the one asked for is
  /// anything stored and the connection made again.
  Future<void> apply(ProfileEntity profile, ExitRole target) async {
    if (state.isLoading) return;
    final override = ExitChoice.overrideFor(profile, target);
    if (override == null) return;
    final t = ref.read(translationsProvider).requireValue;
    final notification = ref.read(inAppNotificationControllerProvider);
    state = const AsyncLoading();
    await ref.read(hapticServiceProvider.notifier).lightImpact();
    final repository = ref.read(profileRepositoryProvider).requireValue;
    final result = await repository.switchExit(profile.id, override, target, cancelToken: CancelToken()).run();
    final failure = result.getLeft().toNullable();
    if (failure != null) {
      // the kind of failure only: the link of the subscription is not written anywhere
      loggy.warning('could not switch the way out to ${target.key}: ${failure.runtimeType}');
      state = AsyncError(failure, StackTrace.current);
      notification.showErrorToast(t.fork.exits.failed);
      return;
    }
    loggy.info('the way out is now ${target.key}');
    state = const AsyncData(unit);
    final updated = (await repository.getById(profile.id).run()).getOrElse((_) => null);
    final active = await ref.read(activeProfileProvider.future);
    if (updated != null && active?.id == profile.id) {
      await ref.read(connectionNotifierProvider.notifier).reconnect(updated);
    }
    notification.showSuccessToast(
      t.fork.exits.switched(name: target == ExitRole.warp ? t.fork.exits.warp : t.fork.exits.main),
    );
  }
}

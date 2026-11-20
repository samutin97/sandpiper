import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/notification/in_app_notification_controller.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/data/profile_repository.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/model/profile_exits.dart';
import 'package:hiddify/features/profile/model/profile_failure.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/profile/notifier/exit_choice_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _main = 'https://example.org/sub/main-token';
const _warp = 'https://example.org/sub/warp-token';

String _b64(String text) => base64Url.encode(utf8.encode(text)).replaceAll('=', '');

final _mainHeader = 'v=1;cur=main;alt=warp;alt-url=${_b64(_warp)}';
final _warpHeader = 'v=1;cur=warp;alt=main;alt-url=${_b64(_main)}';

final _before = RemoteProfileEntity(
  id: 'p1',
  active: true,
  name: 'subscription',
  url: _main,
  lastUpdate: DateTime(2026, 11, 20, 10),
  populatedHeaders: {'profile-exits': _mainHeader},
);

/// The repository: a switch stores the profile as the pair's subscription makes it, or fails and
/// stores nothing, as the real one does.
class _Repository implements ProfileRepository {
  _Repository(this.stored, {this.failure});

  RemoteProfileEntity stored;
  ProfileFailure? failure;
  final switches = <ExitRole>[];

  @override
  TaskEither<ProfileFailure, Unit> switchExit(
    String id,
    UserOverride userOverride,
    ExitRole target, {
    CancelToken? cancelToken,
  }) => TaskEither(() async {
    switches.add(target);
    if (failure != null) return left(failure!);
    stored = stored.copyWith(
      userOverride: userOverride,
      populatedHeaders: {'profile-exits': target == ExitRole.warp ? _warpHeader : _mainHeader},
    );
    return right(unit);
  });

  @override
  TaskEither<ProfileFailure, ProfileEntity?> getById(String id) => TaskEither.right(stored.id == id ? stored : null);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

class _ActiveProfile extends ActiveProfile {
  @override
  Stream<ProfileEntity?> build() => Stream.value(_before);
}

class _Connection extends ConnectionNotifier {
  final reconnected = <ProfileEntity?>[];

  @override
  Stream<ConnectionStatus> build() => Stream.value(const ConnectionStatus.connected());

  @override
  Future<void> reconnect(ProfileEntity? profile) async => reconnected.add(profile);
}

class _Toasts extends InAppNotificationController {
  final shown = <String>[];

  @override
  void showErrorToast(String message) => shown.add('error: $message');

  @override
  void showSuccessToast(String message, {ToastAction? action}) => shown.add('success: $message');

  @override
  void showInfoToast(String message, {ToastAction? action}) => shown.add('info: $message');
}

void main() {
  late _Connection connection;
  late _Toasts toasts;

  Future<(ProviderContainer, _Repository)> open({ProfileFailure? failure}) async {
    SharedPreferences.setMockInitialValues({'haptic_feedback': false});
    final repository = _Repository(_before, failure: failure);
    connection = _Connection();
    toasts = _Toasts();
    final container = ProviderContainer(
      overrides: [
        profileRepositoryProvider.overrideWith((ref) => Future.value(repository)),
        activeProfileProvider.overrideWith(_ActiveProfile.new),
        connectionNotifierProvider.overrideWith(() => connection),
        inAppNotificationControllerProvider.overrideWithValue(toasts),
        translationsProvider.overrideWith((ref) => AppLocale.en.build()),
      ],
    );
    addTearDown(container.dispose);
    await container.read(sharedPreferencesProvider.future);
    await container.read(translationsProvider.future);
    await container.read(profileRepositoryProvider.future);
    await container.read(activeProfileProvider.future);
    await container.read(connectionNotifierProvider.future);
    return (container, repository);
  }

  test('taking the other way out stores the pair, reconnects with it, and tells the user', () async {
    final (container, repository) = await open();

    await container.read(exitChoiceNotifierProvider.notifier).apply(_before, ExitRole.warp);

    expect(repository.switches, [ExitRole.warp]);
    expect(repository.stored.userOverride?.exitUrl, _warp);
    expect(repository.stored.url, _main, reason: 'the profile keeps its own link');
    expect(connection.reconnected, hasLength(1));
    final sent = jsonDecode(connection.reconnected.single!.profileOverride()) as Map<String, dynamic>;
    expect(sent['exit-choice'], 'warp');
    expect(toasts.shown.single, startsWith('success'));
  });

  test('a subscription that does not load leaves the way out and the connection as they were', () async {
    final (container, repository) = await open(failure: const ProfileFailure.exitUnavailable());

    await container.read(exitChoiceNotifierProvider.notifier).apply(_before, ExitRole.warp);

    expect(repository.stored, _before, reason: 'nothing stored');
    expect(connection.reconnected, isEmpty, reason: 'no reconnect');
    expect(toasts.shown.single, startsWith('error'));
    expect(container.read(exitChoiceNotifierProvider).hasError, isTrue);
    // and the way out is still the one before, so it can be tried again
    await container.read(exitChoiceNotifierProvider.notifier).apply(_before, ExitRole.warp);
    expect(repository.switches, hasLength(2));
  });

  test('the way out already in use is no switch', () async {
    final (container, repository) = await open();
    await container.read(exitChoiceNotifierProvider.notifier).apply(_before, ExitRole.main);
    expect(repository.switches, isEmpty);
    expect(connection.reconnected, isEmpty);
  });

  test('back to the main one goes through the profile\'s own link', () async {
    final (container, repository) = await open();
    final notifier = container.read(exitChoiceNotifierProvider.notifier);
    await notifier.apply(_before, ExitRole.warp);
    await notifier.apply(repository.stored, ExitRole.main);
    expect(repository.switches, [ExitRole.warp, ExitRole.main]);
    expect(repository.stored.userOverride?.exitUrl, isNull);
    expect(repository.stored.fetchUrl, _main);
    expect(connection.reconnected, hasLength(2));
  });

  test('no toast, no log shows the link of the pair', () async {
    final (container, repository) = await open();
    await container.read(exitChoiceNotifierProvider.notifier).apply(_before, ExitRole.warp);
    for (final text in toasts.shown) {
      expect(text, isNot(contains('warp-token')));
      expect(text, isNot(contains(_b64(_warp))));
    }
    expect(repository.switches, isNotEmpty);
  });
}

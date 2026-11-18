import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/data/profile_repository.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/model/profile_failure.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/profile/notifier/profile_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// The subscription as it was, and as its server gives it now: a second server's variants (11-20)
/// ranked first.
const _url = 'https://sub.example.com/sub/token';
const _oldPolicy = 'v=1; t=auto:2,3; t=fallback:9; t=last-resort,confirm,max=60:10';
const _newPolicy = 'v=1; t=auto:12,13; t=auto:2,3; t=fallback:9,19; t=last-resort,confirm,max=60:10,20';

final _before = ProfileEntity.remote(
  id: 'p1',
  active: true,
  name: 'subscription',
  url: _url,
  lastUpdate: DateTime(2026, 11, 18, 10),
  populatedHeaders: {'profile-policy': _oldPolicy, 'profile-probe': 'path=/files/64k.bin'},
);

/// The repository: an update stores the new headers, as the real one stores the downloaded ones.
class _Repository implements ProfileRepository {
  _Repository(this.stored);

  ProfileEntity stored;

  @override
  TaskEither<ProfileFailure, Unit> upsertRemote(
    String url, {
    UserOverride? userOverride,
    CancelToken? cancelToken,
    bool activate = false,
  }) => TaskEither(() async {
    stored = (stored as RemoteProfileEntity).copyWith(
      lastUpdate: DateTime(2026, 11, 18, 22),
      populatedHeaders: {'profile-policy': _newPolicy, 'profile-probe': 'path=/files/64k.bin'},
    );
    return right(unit);
  });

  @override
  TaskEither<ProfileFailure, ProfileEntity?> getById(String id) =>
      TaskEither.right(stored.id == id ? stored : null);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

/// The active profile as the app read it before the update.
class _ActiveProfile extends ActiveProfile {
  @override
  Stream<ProfileEntity?> build() => Stream.value(_before);
}

/// A running connection that records the profiles it is reconnected with.
class _Connection extends ConnectionNotifier {
  final reconnected = <ProfileEntity?>[];

  @override
  Stream<ConnectionStatus> build() => Stream.value(const ConnectionStatus.connected());

  @override
  Future<void> reconnect(ProfileEntity? profile) async => reconnected.add(profile);
}

/// The `tier-policy` setting the core gets for [profile] (ConnectionRepository.applyConfigOption).
Object? _tierPolicy(ProfileEntity? profile) =>
    (jsonDecode(profile!.profileOverride()) as Map<String, dynamic>)['tier-policy'];

void main() {
  // The live case (Windows, 5.9.8-sp.12): the subscription's server added a second server and a new
  // ranking; "update profile" while connected restarted the core, which went on choosing by the old
  // ranking until the app was started again. A scheduled update (isBulk) and one by hand (after its
  // question about going around the tunnel) take the same path from the stored update on.
  test('an update while connected sends the new ranking to the core', () async {
    final repository = _Repository(_before);
    final connection = _Connection();
    final container = ProviderContainer(
      overrides: [
        profileRepositoryProvider.overrideWith((ref) => Future.value(repository)),
        activeProfileProvider.overrideWith(_ActiveProfile.new),
        connectionNotifierProvider.overrideWith(() => connection),
      ],
    );
    addTearDown(container.dispose);
    await container.read(profileRepositoryProvider.future);
    await container.read(activeProfileProvider.future);
    await container.read(connectionNotifierProvider.future);

    await container
        .read(updateProfileNotifierProvider('p1').notifier)
        .updateProfile(_before as RemoteProfileEntity, isBulk: true);

    expect(connection.reconnected, hasLength(1));
    final tiers = _tierPolicy(connection.reconnected.single)! as Map<String, dynamic>;
    expect(tiers['policy'], contains('t=auto:12,13'), reason: 'the new ranking, not the one read before the update');
    expect(tiers['policy'], isNot(equals((_tierPolicy(_before)! as Map<String, dynamic>)['policy'])));
    expect(tiers['probe-host'], 'sub.example.com');
  });
}

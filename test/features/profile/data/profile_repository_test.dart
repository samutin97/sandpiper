import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hiddify/core/db/db.dart';
import 'package:hiddify/features/profile/data/profile_data_mapper.dart';
import 'package:hiddify/features/profile/data/profile_data_source.dart';
import 'package:hiddify/features/profile/data/profile_parser.dart';
import 'package:hiddify/features/profile/data/profile_path_resolver.dart';
import 'package:hiddify/features/profile/data/profile_repository.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/model/profile_exits.dart';
import 'package:hiddify/features/profile/model/profile_failure.dart';
import 'package:hiddify/features/profile/model/profile_sort_enum.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service.dart';

/// Writes the temp file inside the task, like the real download does.
class _FakeParser implements ProfileParser {
  TaskEither<ProfileFailure, ProfileEntriesCompanion> _download(String tempFilePath) => TaskEither(() async {
    await File(tempFilePath).writeAsString('{}');
    return right(const ProfileEntriesCompanion());
  });

  @override
  TaskEither<ProfileFailure, ProfileEntriesCompanion> addRemote({
    required String id,
    required String url,
    required String tempFilePath,
    required UserOverride? userOverride,
    CancelToken? cancelToken,
    bool active = true,
  }) => _download(tempFilePath);

  @override
  TaskEither<ProfileFailure, ProfileEntriesCompanion> updateRemote({
    required RemoteProfileEntity rp,
    required String tempFilePath,
    CancelToken? cancelToken,
    ExitRole? switchTo,
  }) => _download(tempFilePath);

  /// The profiles an offline update was made with.
  static final offlineSeen = <ProfileEntity>[];

  @override
  Either<ProfileFailure, ProfileEntriesCompanion> offlineUpdate({
    required ProfileEntity profile,
    required String tempFilePath,
  }) {
    offlineSeen.add(profile);
    return right(const ProfileEntriesCompanion());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeDataSource implements ProfileDataSource {
  _FakeDataSource([this.entry, this.entries = const []]);

  final ProfileEntry? entry;
  final List<ProfileEntry> entries;

  @override
  Stream<List<ProfileEntry>> watchAll({required ProfilesSort sort, required SortMode sortMode}) =>
      Stream.value(entries);

  @override
  Future<ProfileEntry?> getById(String id) async => entry;

  @override
  Future<ProfileEntry?> getByUrl(String url) async => entry;

  @override
  Future<void> insert(ProfileEntriesCompanion entry) async {}

  /// The edits made, in order.
  final edits = <(String, ProfileEntriesCompanion)>[];

  @override
  Future<void> edit(String id, ProfileEntriesCompanion entry) async => edits.add((id, entry));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _UnusedCore implements HiddifyCoreService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _UnusedOptions implements ConfigOptionRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Stands in for the core check: it records whether the temp file still exists when the config is validated.
class _Repo extends ProfileRepositoryImpl {
  _Repo(ProfileDataSource dataSource, ProfilePathResolver paths, {this.valid = true})
    : super(
        profileDataSource: dataSource,
        profilePathResolver: paths,
        singbox: _UnusedCore(),
        configOptionRepository: _UnusedOptions(),
        profileParser: _FakeParser(),
      );

  final bool valid;
  bool? tempFileSeen;

  @override
  TaskEither<ProfileFailure, Unit> validateConfig(String path, String tempPath, String? profileOverride, bool debug) =>
      TaskEither(() async {
        tempFileSeen = File(tempPath).existsSync();
        return valid ? right(unit) : left(const ProfileFailure.invalidConfig());
      });
}

void main() {
  late Directory root;
  late ProfilePathResolver paths;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('hiddify_profile_test');
    paths = ProfilePathResolver(root);
    await paths.directory.create();
  });

  tearDown(() => root.delete(recursive: true));

  /// The `<id>.tmp.json` files left in the configs folder.
  List<String> leftTempFiles() =>
      paths.directory.listSync().map((f) => f.path).where((path) => path.endsWith('.tmp.json')).toList();

  final remoteEntry = ProfileEntry(
    id: 'remote-id',
    type: ProfileType.remote,
    active: true,
    name: 'remote',
    url: 'https://example.com/sub',
    lastUpdate: DateTime(2026),
    pinned: false,
  );

  group("temp file is deleted after the task", () {
    test("upsertRemote adds a profile", () async {
      final repo = _Repo(_FakeDataSource(), paths);
      final result = await repo.upsertRemote('https://example.com/sub').run();
      expect(result.isRight(), true);
      expect(repo.tempFileSeen, true);
      expect(leftTempFiles(), isEmpty);
    });

    test("upsertRemote fails to add a profile", () async {
      final repo = _Repo(_FakeDataSource(), paths, valid: false);
      final result = await repo.upsertRemote('https://example.com/sub').run();
      expect(result.isLeft(), true);
      expect(repo.tempFileSeen, true);
      expect(leftTempFiles(), isEmpty);
    });

    test("upsertRemote updates a profile", () async {
      final repo = _Repo(_FakeDataSource(remoteEntry), paths);
      final result = await repo.upsertRemote('https://example.com/sub').run();
      expect(result.isRight(), true);
      expect(repo.tempFileSeen, true);
      expect(leftTempFiles(), isEmpty);
    });

    test("offlineUpdate updates a profile", () async {
      final repo = _Repo(_FakeDataSource(remoteEntry), paths);
      final result = await repo.offlineUpdate(remoteEntry.toEntity(), '{}').run();
      expect(result.isRight(), true);
      expect(repo.tempFileSeen, true);
      expect(leftTempFiles(), isEmpty);
    });

    // the details screen opened, the way out switched, the screen saved: the way out stays
    test("offlineUpdate keeps the way out of the pair as it is stored, not as the screen opened with it", () async {
      const warp = 'https://example.com/warp';
      _FakeParser.offlineSeen.clear();
      final stored = remoteEntry.copyWith(userOverride: Value(const UserOverride(exitUrl: warp, keepTop: 1).toStr()));
      final repo = _Repo(_FakeDataSource(stored), paths);
      // the screen opened before the switch: no way out in its copy, and a rename in it
      final opened = remoteEntry.toEntity().copyWith(userOverride: const UserOverride(name: 'mine'));
      expect((await repo.offlineUpdate(opened, '{}').run()).isRight(), true);
      final saved = _FakeParser.offlineSeen.single.userOverride!;
      expect(saved.exitUrl, warp);
      expect(saved.name, 'mine', reason: "the screen's own changes are saved");
      expect(saved.keepTop, isNull);
      // and the other way: the screen opened on the pair, saved after a switch back
      _FakeParser.offlineSeen.clear();
      final back = _Repo(
        _FakeDataSource(remoteEntry.copyWith(userOverride: Value(const UserOverride().toStr()))),
        paths,
      );
      final onPair = remoteEntry.toEntity().copyWith(userOverride: const UserOverride(exitUrl: warp));
      await back.offlineUpdate(onPair, '{}').run();
      expect(_FakeParser.offlineSeen.single.userOverride?.exitUrl, isNull);
    });
  });

  group("adding a profile that is already there", () {
    /// Whether [source] was told to make [id] the active profile.
    bool activated(_FakeDataSource source, String id) =>
        source.edits.any((edit) => edit.$1 == id && edit.$2.active == const Value(true));

    test("selects it", () async {
      final source = _FakeDataSource(remoteEntry.copyWith(active: false));
      final result = await _Repo(source, paths).upsertRemote(remoteEntry.url!, activate: true).run();
      expect(result.isRight(), true);
      expect(activated(source, remoteEntry.id), true);
    });

    test("selects it even when its update fails", () async {
      final source = _FakeDataSource(remoteEntry.copyWith(active: false));
      final result = await _Repo(source, paths, valid: false).upsertRemote(remoteEntry.url!, activate: true).run();
      expect(result.isLeft(), true);
      expect(activated(source, remoteEntry.id), true);
    });

    test("an update does not select it", () async {
      final source = _FakeDataSource(remoteEntry.copyWith(active: false));
      await _Repo(source, paths).upsertRemote(remoteEntry.url!).run();
      expect(activated(source, remoteEntry.id), false);
    });

    test("the active one is left as it is", () async {
      final source = _FakeDataSource(remoteEntry.copyWith(active: true));
      await _Repo(source, paths).upsertRemote(remoteEntry.url!, activate: true).run();
      expect(activated(source, remoteEntry.id), false);
    });
  });

  // hiddify-app#2422: one profile saved with data this version can not read failed the whole list
  test("watchAll lists the profiles saved with data that can not be read", () async {
    final entries = [
      remoteEntry,
      remoteEntry.copyWith(id: 'null-headers', populatedHeaders: const Value('null')),
      remoteEntry.copyWith(id: 'bad-headers', populatedHeaders: const Value('{not json')),
      remoteEntry.copyWith(id: 'bad-choices', userOverride: const Value('{not json')),
      remoteEntry.copyWith(id: 'no-url', url: const Value(null)),
    ];
    final repo = _Repo(_FakeDataSource(null, entries), paths);
    final result = await repo.watchAll().first;
    expect(result.getOrElse((f) => throw f).map((p) => p.id), entries.map((e) => e.id));
  });
}

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hiddify/core/directories/directories_provider.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/directories.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/connection/data/connection_repository.dart';
import 'package:hiddify/features/connection/model/connection_failure.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/profile/data/profile_path_resolver.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/hiddifycore/core_interface/core_interface.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service.dart';
import 'package:hiddify/singbox/model/core_status.dart';
import 'package:hiddify/singbox/model/singbox_config_option.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The failure measured on Windows (5.9.8-sp.10): the saved port in a range the system reserves.
String refused(int port) =>
    "start inbound: start inbound/mixed[mixed-in127.0.0.1]: listen tcp 127.0.0.1:$port: bind: "
    "An attempt was made to access a socket in a way forbidden by its access permissions.";

class _Directories extends AppDirectories {
  _Directories(this.dir);

  final Directory dir;

  @override
  Future<Directories> build() async => (baseDir: dir, workingDir: dir, tempDir: dir);
}

class _FakeCoreInterface implements CoreInterface {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The core service as the desktop has it: a start returns once the core has the request, and the
/// outcome comes on the status stream ([statuses], which the test drives). A start listed in
/// [failInResult] also returns its failure, as on Android, where the start waits for the outcome.
class _FakeCore implements HiddifyCoreService {
  final statuses = StreamController<CoreStatus>.broadcast();
  final startedPorts = <int>[];
  final failInResult = <int, ConnectionFailure>{};

  /// When set, a start that returns its failure does so only once it completes.
  Completer<void>? holdResult;
  late SingboxConfigOption _options;

  @override
  final CoreInterface core = _FakeCoreInterface();

  @override
  TaskEither<String, Unit> setup() => TaskEither.of(unit);

  @override
  Stream<CoreStatus> watchStatus() => statuses.stream;

  @override
  TaskEither<String, Unit> changeOptions(SingboxConfigOption options) {
    _options = options;
    return TaskEither.of(unit);
  }

  @override
  TaskEither<ConnectionFailure, Unit> start(String path, String name, bool disableMemoryLimit) => TaskEither(() async {
    startedPorts.add(_options.mixedPort);
    statuses.add(const CoreStatus.starting());
    if (failInResult[startedPorts.length] case final failure?) {
      await holdResult?.future;
      return left(failure);
    }
    return right(unit);
  });

  @override
  TaskEither<String, Unit> stop() => TaskEither.of(unit);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory dir;
  late ProviderContainer container;
  late _FakeCore core;
  late ConnectionRepository repo;
  late List<ConnectionStatus> shown;
  late StreamSubscription<ConnectionStatus> watch;
  final profile = ProfileEntity.local(id: 'p', active: true, name: 'p', lastUpdate: DateTime(2026));

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('port_repair');
    SharedPreferences.setMockInitialValues({'mixed-port': 50100, 'clash-api-port': 40001});
    container = ProviderContainer(
      overrides: [
        appDirectoriesProvider.overrideWith(() => _Directories(dir)),
        translationsProvider.overrideWith((ref) => AppLocale.en.build()),
      ],
    );
    await container.read(appDirectoriesProvider.future);
    await container.read(translationsProvider.future);
    final prefs = await container.read(sharedPreferencesProvider.future);
    core = _FakeCore();
    final provider = Provider<ConnectionRepository>(
      (ref) => ConnectionRepositoryImpl(
        ref: ref,
        directories: (baseDir: dir, workingDir: dir, tempDir: dir),
        singbox: core,
        configOptionRepository: ConfigOptionRepository(
          preferences: prefs,
          getConfigOptions: () => ref.read(ConfigOptions.singboxConfigOptions),
        ),
        profilePathResolver: ProfilePathResolver(dir),
      ),
    );
    repo = container.read(provider);
    shown = [];
    watch = repo.watchConnectionStatus().listen(shown.add);
  });

  tearDown(() async {
    await watch.cancel();
    container.dispose();
    await dir.delete(recursive: true);
  });

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 50));
  bool failed(ConnectionStatus status) => status is Disconnected && status.connectionFailure != null;

  Future<void> connected() async {
    final result = await repo.connect(profile, false).run();
    expect(result.isRight(), isTrue, reason: '$result');
  }

  /// The core reports the failed start, then the core service stops the failed core: the stop, and
  /// the failure once more (8 ms later in the log).
  Future<void> coreFails(String message) async {
    core.statuses.add(CoreStatus.stopped(alert: CoreAlert.startService, message: message));
    await settle();
    core.statuses.add(const CoreStatus.stopping());
    core.statuses.add(CoreStatus.stopped(alert: CoreAlert.startService, message: message));
    await settle();
  }

  // D9-01, as measured on Windows: connect() returned, and the failure came after, on the status
  // stream. The repair in the result of connect() never saw it; the user saw "Could not connect",
  // and the port stayed.
  test('a start that fails after connect() on the saved port gets a new port and runs again', () async {
    await connected();
    await coreFails(refused(50100));
    expect(core.startedPorts, hasLength(2), reason: 'no second start');
    final next = core.startedPorts[1];
    expect(next, isNot(50100));
    expect(container.read(ConfigOptions.mixedPort), next);
    core.statuses.add(const CoreStatus.started());
    await settle();
    expect(shown.where(failed), isEmpty, reason: 'the first failure was shown: $shown');
    expect(shown.last, const Connected());
  });

  test('the retry fails too: its failure shows, and there is no third start', () async {
    await connected();
    await coreFails(refused(50100));
    await coreFails(refused(core.startedPorts.last));
    expect(core.startedPorts, hasLength(2));
    expect(shown.where(failed), isNotEmpty);
    expect(shown.last, isA<Disconnected>());
  });

  test('another failure is shown at once, and not retried', () async {
    await connected();
    await coreFails("start inbound/tun[tun-in]: configure tun interface: Access is denied.");
    expect(core.startedPorts, [50100]);
    expect(shown.where(failed), isNotEmpty);
    expect(container.read(ConfigOptions.mixedPort), 50100);
  });

  test('a port the user set for LAN sharing is not repaired', () async {
    await connected();
    await coreFails("start inbound: listen tcp 0.0.0.0:12338: bind: address already in use");
    expect(core.startedPorts, [50100]);
    expect(shown.where(failed), isNotEmpty);
  });

  test('a connect that started its core repairs nothing later', () async {
    await connected();
    core.statuses.add(const CoreStatus.started());
    await settle();
    await coreFails(refused(50100));
    expect(core.startedPorts, [50100]);
    expect(shown.where(failed), isNotEmpty);
  });

  // Android: the start waits for the outcome, and also returns the failure.
  test('a start that returns its failure waits for the repair, and connect() gets the retry', () async {
    core.failInResult[1] = ConnectionFailure.unexpected("startService - ${refused(50100)}");
    final connecting = repo.connect(profile, false).run();
    while (core.startedPorts.isEmpty) {
      await settle();
    }
    await coreFails(refused(50100));
    final result = await connecting;
    expect(result.isRight(), isTrue, reason: '$result');
    expect(core.startedPorts, hasLength(2));
    expect(shown.where(failed), isEmpty, reason: '$shown');
  });

  // Android as it goes: the core's report of the failure comes first, then the start returns it.
  test('a failure reported before the start returns it is repaired once', () async {
    core.failInResult[1] = ConnectionFailure.unexpected("startService - ${refused(50100)}");
    core.holdResult = Completer<void>();
    final connecting = repo.connect(profile, false).run();
    while (core.startedPorts.isEmpty) {
      await settle();
    }
    core.statuses.add(CoreStatus.stopped(alert: CoreAlert.startService, message: refused(50100)));
    await settle();
    core.holdResult!.complete();
    await settle();
    core.statuses.add(const CoreStatus.stopping());
    core.statuses.add(CoreStatus.stopped(alert: CoreAlert.startService, message: refused(50100)));
    final result = await connecting;
    expect(result.isRight(), isTrue, reason: '$result');
    expect(core.startedPorts, hasLength(2));
    expect(shown.where(failed), isEmpty, reason: '$shown');
  });

  test('a disconnect before the retry ends the repair', () async {
    await connected();
    core.statuses.add(CoreStatus.stopped(alert: CoreAlert.startService, message: refused(50100)));
    await settle();
    await repo.disconnect().run();
    core.statuses.add(const CoreStatus.stopped());
    await settle();
    expect(core.startedPorts, [50100]);
    expect(container.read(ConfigOptions.mixedPort), 50100);
  });
}

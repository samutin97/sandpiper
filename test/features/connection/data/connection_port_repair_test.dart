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

  /// A start (by its number, from 1) that returns only once its completer does, as the core service's
  /// start does on the desktop: it waits for the outcome on the status stream.
  final holdOutcome = <int, Completer<void>>{};

  /// Statuses a start publishes right after STARTING, before it returns.
  final afterStarting = <CoreStatus>[];

  /// Published by a start before it returns its failure (Android: the platform's stop).
  CoreStatus? beforeFailure;

  @override
  bool Function(String message)? handledLocalBind;
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
    final number = startedPorts.length;
    statuses.add(const CoreStatus.starting());
    afterStarting.forEach(statuses.add);
    if (failInResult[number] case final failure?) {
      if (beforeFailure case final status?) statuses.add(status);
      await holdResult?.future;
      return left(failure);
    }
    await holdOutcome[number]?.future;
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

  // D11-01: the status showed "tap to connect" for a moment between the two attempts.
  // The desktop's order: the core reports the failure, STOPPING, and then a plain STOPPED whose message
  // is empty (not null: it comes off the wire), before the second start reports anything.
  test('no disconnected status between the attempts: the failed core stops with an empty message', () async {
    core.holdOutcome[2] = Completer<void>();
    await connected();
    core.statuses.add(CoreStatus.stopped(alert: CoreAlert.startService, message: refused(50100)));
    await settle();
    core.statuses.add(const CoreStatus.stopping());
    core.statuses.add(const CoreStatus.stopped(message: ''));
    await settle();
    core.statuses.add(CoreStatus.stopped(alert: CoreAlert.startService, message: refused(50100)));
    await settle();
    expect(core.startedPorts, hasLength(2));
    expect(shown.whereType<Disconnected>(), isEmpty, reason: '$shown');
    core.holdOutcome[2]!.complete();
    core.statuses.add(const CoreStatus.started());
    await settle();
    expect(shown.last, const Connected());
    expect(shown.whereType<Disconnected>(), isEmpty, reason: '$shown');
  });

  // Android: the start returns its failure, and the platform's stop comes before the core's report.
  test('no disconnected status when the platform stops before the failure is reported', () async {
    core.failInResult[1] = ConnectionFailure.unexpected("startService - ${refused(50100)}");
    core.beforeFailure = const CoreStatus.stopped();
    core.holdResult = Completer<void>();
    final connecting = repo.connect(profile, false).run();
    while (core.startedPorts.isEmpty) {
      await settle();
    }
    await settle();
    core.statuses.add(CoreStatus.stopped(alert: CoreAlert.startService, message: refused(50100)));
    await settle();
    core.holdResult!.complete();
    await settle();
    core.statuses.add(const CoreStatus.stopping());
    core.statuses.add(CoreStatus.stopped(alert: CoreAlert.startService, message: refused(50100)));
    final result = await connecting;
    expect(result.isRight(), isTrue, reason: '$result');
    expect(shown.whereType<Disconnected>(), isEmpty, reason: '$shown');
  });

  // The good port: the core answers a new status listener with the state it is in (stopped) right
  // after the app said STARTING.
  test('no disconnected status when a stale stop arrives while the connect runs', () async {
    core.afterStarting.add(const CoreStatus.stopped(message: ''));
    core.holdOutcome[1] = Completer<void>();
    final connecting = repo.connect(profile, false).run();
    await settle();
    core.statuses.add(const CoreStatus.started());
    core.holdOutcome[1]!.complete();
    expect((await connecting).isRight(), isTrue);
    await settle();
    expect(shown.whereType<Disconnected>(), isEmpty, reason: '$shown');
    expect(shown.last, const Connected());
  });

  test('a stop that ends the connect is shown once the connect is over', () async {
    core.afterStarting.add(const CoreStatus.stopped(message: ''));
    await connected();
    await settle();
    expect(shown.last, isA<Disconnected>());
  });

  test('a disconnect while the second attempt runs cancels it: disconnected, no error, no third start', () async {
    core.holdOutcome[2] = Completer<void>();
    await connected();
    await coreFails(refused(50100));
    expect(core.startedPorts, hasLength(2));
    await repo.disconnect().run();
    core.statuses.add(const CoreStatus.stopping());
    // the failed core's report, late
    core.statuses.add(CoreStatus.stopped(alert: CoreAlert.startService, message: refused(50100)));
    core.statuses.add(const CoreStatus.stopped(message: ''));
    core.holdOutcome[2]!.complete();
    await settle();
    expect(core.startedPorts, hasLength(2));
    expect(shown.where(failed), isEmpty, reason: '$shown');
    expect(shown.last, const Disconnected());
  });

  // D11-01 / A: the core's own line about the failed bind is handled while the repair is armed.
  test('the failed bind of the armed connect is a handled line, and no other is', () async {
    expect(core.handledLocalBind, isNotNull);
    expect(core.handledLocalBind!(refused(50100)), isFalse, reason: 'no connect yet');
    await connected();
    expect(core.handledLocalBind!(refused(50100)), isTrue);
    expect(core.handledLocalBind!(refused(50101)), isFalse);
    expect(core.handledLocalBind!("start inbound/tun[tun-in]: configure tun interface: Access is denied."), isFalse);
    await coreFails(refused(50100));
    expect(core.handledLocalBind!(refused(50100)), isTrue, reason: 'the line comes after the status too');
    final next = core.startedPorts.last;
    expect(core.handledLocalBind!(refused(next)), isFalse, reason: 'the new port failing is not handled');
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

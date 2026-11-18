import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:hiddify/core/directories/directories_provider.dart';
import 'package:hiddify/core/model/directories.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/hiddifycore/core_interface/core_interface.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcommon/common.pb.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore_service.pbgrpc.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The core's side of the log stream, on loopback in this process (no core is started): it records the
/// level each listener asked for and which of them are still open.
class _LogServer extends CoreServiceBase {
  final requested = <LogLevel>[];
  int open = 0;

  @override
  Stream<LogMessage> logListener(ServiceCall call, LogRequest request) {
    requested.add(request.level);
    open++;
    late final StreamController<LogMessage> controller;
    controller = StreamController<LogMessage>(onCancel: () => open--);
    return controller.stream;
  }

  @override
  Future<Empty> close(ServiceCall call, CloseRequest request) async => Empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => throw GrpcError.unimplemented();
}

/// Both channels reach the core, as on Android: it is one process.
class _SharedProcessCore extends CoreInterface {
  _SharedProcessCore(int port) {
    CoreClient client() => CoreClient(
      ClientChannel(
        InternetAddress.loopbackIPv4.address,
        port: port,
        options: const ChannelOptions(credentials: ChannelCredentials.insecure()),
      ),
    );
    fgClient = client();
    bgClient = client();
  }

  @override
  bool get coreSharesProcess => true;

  @override
  Future<String> setup(Directories directories, bool debug, int mode) async => '';
}

class _Directories extends AppDirectories {
  _Directories(this.dir);

  final Directory dir;

  @override
  Future<Directories> build() async => (baseDir: dir, workingDir: dir, tempDir: dir);
}

void main() {
  late Directory dir;
  late Server server;
  late _LogServer logs;
  late ProviderContainer container;
  late HiddifyCoreService service;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('core_logs');
    logs = _LogServer();
    server = Server.create(services: [logs]);
    await server.serve(address: InternetAddress.loopbackIPv4, port: 0);
    SharedPreferences.setMockInitialValues({'log-level': 'info'});
    container = ProviderContainer(overrides: [appDirectoriesProvider.overrideWith(() => _Directories(dir))]);
    await container.read(appDirectoriesProvider.future);
    await container.read(sharedPreferencesProvider.future);
    final provider = Provider<HiddifyCoreService>((ref) => HiddifyCoreService(ref, core: _SharedProcessCore(server.port!)));
    service = container.read(provider);
  });

  tearDown(() async {
    await service.stopListenSingle('');
    container.dispose();
    await server.shutdown();
    await dir.delete(recursive: true);
  });

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 200));

  // E12-02: the core's warnings of a run nobody watched (the app in the background) were lost: the
  // listeners went with the foreground channel.
  test('paused: one listener at the warning level stays; back: the usual listeners, no doubles', () async {
    await service.startListeningLogs('fg', service.core.fgClient);
    await service.startListeningLogs('bg', service.core.bgClient);
    await settle();
    // the user's level (info by default), on the foreground channel only: the channels share the core
    expect(logs.requested, [LogLevel.INFO]);
    expect(logs.open, 1);

    await service.closeFront();
    await settle();
    expect(logs.requested.last, LogLevel.WARNING);
    expect(logs.open, 1, reason: 'the foreground listener is gone, one warning listener is open');

    // the core was started again meanwhile (the VPN service): still one listener
    await service.startListeningLogs('bg', service.core.bgClient);
    await settle();
    expect(logs.requested.last, LogLevel.WARNING);
    expect(logs.open, 1);

    await service.setup().run();
    await settle();
    expect(logs.requested.last, LogLevel.INFO);
    expect(logs.open, 1, reason: 'the warning listener was replaced, not added to');
  });
}

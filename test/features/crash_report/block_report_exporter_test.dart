import 'dart:io';

import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:hiddify/core/directories/directories_provider.dart';
import 'package:hiddify/core/model/directories.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/crash_report/data/block_report_exporter.dart';
import 'package:hiddify/hiddifycore/core_interface/core_interface.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore_service.pbgrpc.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service_provider.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The core's side of the journal call, on loopback in this process: it records the requests and
/// answers with [content], or fails when [fail] is set.
class _JournalServer extends CoreServiceBase {
  _JournalServer(this.content, {this.size = 0});

  final List<int> content;
  final int size;
  bool fail = false;
  final requests = <BlockJournalRequest>[];

  @override
  Future<BlockJournalResponse> blockJournal(ServiceCall call, BlockJournalRequest request) async {
    requests.add(request);
    if (fail) throw const GrpcError.unavailable('no core');
    return BlockJournalResponse(content: request.export ? content : null, size: Int64(size));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw const GrpcError.unimplemented();
}

class _TestCore extends CoreInterface {
  _TestCore(int fg, int? bg, {required this.shared}) {
    CoreClient client(int port) => CoreClient(
      ClientChannel(
        InternetAddress.loopbackIPv4.address,
        port: port,
        options: const ChannelOptions(credentials: ChannelCredentials.insecure()),
      ),
    );
    fgClient = client(fg);
    // one channel for both, or two different ones
    bgClient = bg == null ? fgClient : client(bg);
  }

  final bool shared;

  @override
  bool get coreSharesProcess => shared;

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
  late _JournalServer fg;
  late _JournalServer bg;
  late Server fgServer;
  late Server bgServer;
  late ProviderContainer container;

  final fgZip = List<int>.generate(300, (i) => i % 256);
  final bgZip = List<int>.generate(100, (i) => (i * 7) % 256);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('block_report');
    fg = _JournalServer(fgZip, size: 1000);
    bg = _JournalServer(bgZip, size: 24);
    fgServer = Server.create(services: [fg]);
    bgServer = Server.create(services: [bg]);
    await fgServer.serve(address: InternetAddress.loopbackIPv4, port: 0);
    await bgServer.serve(address: InternetAddress.loopbackIPv4, port: 0);
    SharedPreferences.setMockInitialValues({});
  });

  Future<BlockReportExporter> exporter({required bool separate}) async {
    final core = _TestCore(fgServer.port!, separate ? bgServer.port : null, shared: !separate);
    container = ProviderContainer(
      overrides: [
        appDirectoriesProvider.overrideWith(() => _Directories(dir)),
        hiddifyCoreServiceProvider.overrideWith((ref) => HiddifyCoreService(ref, core: core)),
      ],
    );
    await container.read(appDirectoriesProvider.future);
    await container.read(sharedPreferencesProvider.future);
    return container.read(blockReportExporterProvider);
  }

  tearDown(() async {
    container.dispose();
    await fgServer.shutdown();
    await bgServer.shutdown();
    await dir.delete(recursive: true);
  });

  File appLog() => File('${dir.path}${Platform.pathSeparator}app.log');

  test('shared process: one call, the app log tail only, the zip as the core sent it', () async {
    await appLog().writeAsString('line one\nline two\n');
    final file = await (await exporter(separate: false)).export();

    expect(fg.requests, hasLength(1));
    expect(bg.requests, isEmpty);
    final request = fg.requests.single;
    expect(request.export, isTrue);
    expect(request.inline, isTrue);
    expect(request.clear_1, isFalse);
    expect(request.destinationPath, isEmpty);
    expect(request.extraFiles.keys, ['app.log']);
    expect(String.fromCharCodes(request.extraFiles['app.log']!), 'line one\nline two\n');

    expect(file.uri.pathSegments.last, matches(RegExp(r'^net-report-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}\.zip$')));
    expect(await file.readAsBytes(), fgZip);
  });

  test('a new report removes the ones made before, and nothing else', () async {
    final old = File('${dir.path}${Platform.pathSeparator}net-report-2026-01-01T00-00-00.zip');
    final other = File('${dir.path}${Platform.pathSeparator}report-001.zip');
    await old.writeAsBytes([1, 2, 3]);
    await other.writeAsBytes([4, 5, 6]);
    final file = await (await exporter(separate: false)).export();

    expect(old.existsSync(), isFalse);
    expect(other.existsSync(), isTrue);
    expect(file.existsSync(), isTrue);
  });

  test('no app.log: no extra files', () async {
    await (await exporter(separate: false)).export();
    expect(fg.requests.single.extraFiles, isEmpty);
  });

  test('separate background core: its zip goes along as service-core.zip', () async {
    await appLog().writeAsString('x');
    final file = await (await exporter(separate: true)).export();

    expect(bg.requests, hasLength(1));
    expect(bg.requests.single.export, isTrue);
    expect(bg.requests.single.inline, isTrue);
    expect(bg.requests.single.extraFiles, isEmpty);
    expect(bg.requests.single.destinationPath, isEmpty);

    expect(fg.requests, hasLength(1));
    expect(fg.requests.single.extraFiles.keys.toSet(), {'app.log', 'service-core.zip'});
    expect(fg.requests.single.extraFiles['service-core.zip'], bgZip);
    expect(await file.readAsBytes(), fgZip);
  });

  test('the background core failing still gives a report', () async {
    bg.fail = true;
    final file = await (await exporter(separate: true)).export();

    expect(bg.requests, hasLength(1));
    expect(fg.requests.single.extraFiles.containsKey('service-core.zip'), isFalse);
    expect(await file.readAsBytes(), fgZip);
  });

  test('an empty answer is an error', () async {
    fg = _JournalServer(const []);
    await fgServer.shutdown();
    fgServer = Server.create(services: [fg]);
    await fgServer.serve(address: InternetAddress.loopbackIPv4, port: 0);
    expect((await exporter(separate: false)).export(), throwsA(isA<StateError>()));
  });

  test('clear reaches both cores when separate', () async {
    await (await exporter(separate: true)).clear();
    expect(fg.requests.single.clear_1, isTrue);
    expect(fg.requests.single.export, isFalse);
    expect(bg.requests.single.clear_1, isTrue);
  });

  test('clear reaches one core when shared', () async {
    await (await exporter(separate: false)).clear();
    expect(fg.requests, hasLength(1));
    expect(fg.requests.single.clear_1, isTrue);
    expect(bg.requests, isEmpty);
  });

  test('size adds both cores when separate, a failing background core counts 0', () async {
    final separate = await exporter(separate: true);
    expect(await separate.size(), 1024);
    bg.fail = true;
    expect(await separate.size(), 1000);
  });

  test('an app.log over 256 KiB is cut to its last 256 KiB', () async {
    const limit = 256 * 1024;
    final head = List<int>.filled(100 * 1024, 0x41); // dropped
    final tail = List<int>.generate(limit, (i) => 0x30 + i % 10);
    await appLog().writeAsBytes([...head, ...tail]);
    await (await exporter(separate: false)).export();

    final sent = fg.requests.single.extraFiles['app.log']!;
    expect(sent, hasLength(limit));
    expect(sent, tail);
  });
}

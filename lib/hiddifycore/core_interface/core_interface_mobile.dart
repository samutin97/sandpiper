import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:grpc/grpc.dart';
import 'package:hiddify/core/model/directories.dart';
import 'package:hiddify/core/utils/laststeam.dart';
import 'package:hiddify/hiddifycore/core_interface/core_interface.dart';
import 'package:hiddify/hiddifycore/core_interface/grpc_client_identity.dart';
import 'package:hiddify/hiddifycore/core_interface/mtls_channel_cred.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore_service.pbgrpc.dart';
import 'package:hiddify/hiddifycore/generated/v2/hello/hello.pb.dart';
import 'package:hiddify/hiddifycore/generated/v2/hello/hello_service.pbgrpc.dart';
import 'package:hiddify/singbox/model/core_status.dart';

import 'package:hiddify/utils/utils.dart';
import 'package:rxdart/rxdart.dart';

class CoreInterfaceMobile extends CoreInterface with InfraLogger {
  @override
  bool get coreSharesProcess => Platform.isAndroid;

  static const channelPrefix = "com.hiddify.app";
  static const methodChannel = MethodChannel("$channelPrefix/method");
  static const platformChannel = MethodChannel("$channelPrefix/platform");
  static const statusChannel = EventChannel("$channelPrefix/service.status", JSONMethodCodec());
  static const alertsChannel = EventChannel("$channelPrefix/service.alerts", JSONMethodCodec());

  /// Made once and kept in the app's private folder, then reused by every launch and by the
  /// platform service (see GrpcClientIdentity).
  late GrpcClientIdentity _identity;

  // M-01: the fixed ports of upstream (17078/17079), used only with a core that can not take a free
  // port and tell it; the hardened core listens on a free port each start (get_grpc_port).
  static const fixedPortBack = 17079;
  static const fixedPortFront = 17078;
  int portBack = fixedPortBack;
  int portFront = fixedPortFront;

  bool? _hardenedCore;

  /// Whether the in-process core is the fork's hardened one: it reports the free port each control
  /// server took, so the fixed ports are never used, nor probed (D-02).
  Future<bool> _hardened() async {
    if (_hardenedCore != null) return _hardenedCore!;
    if (!Platform.isAndroid) return _hardenedCore = false;
    try {
      return _hardenedCore = await methodChannel.invokeMethod<bool>('core_hardened') ?? false;
    } catch (_) {
      return _hardenedCore = false;
    }
  }

  /// The port the core's control server of [mode] (1 app, 2 VPN service) listens on: with the
  /// hardened core the one it reports, 0 while it is not running; with the official core [fallback].
  Future<int> _grpcPort(int mode, int fallback) async {
    if (!await _hardened()) return fallback;
    try {
      return await methodChannel.invokeMethod<int>('get_grpc_port', mode) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Whether the control server on [port] answers. Port 0 (the hardened core's server not running)
  /// is not probed: D-02, no connection to a port another app may hold.
  Future<bool> _serverUp(int port) async => port > 0 && await isPortOpen('127.0.0.1', port);

  bool _isBgClientAvailable = false;
  bool _debug = false;
  bool _useMtls = false;
  ChannelCredentials _credentials = const ChannelCredentials.insecure();

  late LastStream<CoreStatus> _status;
  StreamSubscription<CoreStatus>? _nativeStatusSubscription;
  final _managedStatus = BehaviorSubject<CoreStatus>.seeded(const CoreStatus.stopped());
  ClientChannel? _fgChannel;
  ClientChannel? _bgChannel;

  bool _isMtlsMode(int mode) => mode == 1 || mode == 2;

  @override
  // Platform VPN/service status is the source of truth on mobile (survives app relaunch).
  Stream<CoreStatus>? get managedStatus => _managedStatus.stream;

  @override
  Future<void> dispose() async {
    await _nativeStatusSubscription?.cancel();
    _nativeStatusSubscription = null;
  }

  @override
  Future<String> setup(Directories directories, bool debug, int mode) async {
    _debug = debug;
    _useMtls = _isMtlsMode(mode);
    // The identity is kept in the private base folder only while the core runs with mTLS: the
    // core and the platform service take its presence as the switch, and trust it by reading the
    // file, so nothing is passed over the method channel.
    final identityDirectory = Directory('${directories.baseDir.path}/grpc');
    if (_useMtls) {
      _identity = await GrpcClientIdentity.loadOrCreate(identityDirectory);
    } else if (await identityDirectory.exists()) {
      await identityDirectory.delete(recursive: true);
    }

    // Created once. setup runs again on every resume, including the one right after the VPN
    // dialog closes; a replaced stream would leave a start that is waiting on it deaf.
    if (_nativeStatusSubscription == null) {
      final status = statusChannel.receiveBroadcastStream().map(CoreStatus.fromEvent);
      final alerts = alertsChannel.receiveBroadcastStream().map(CoreStatus.fromEvent);
      final merged = ValueConnectableStream(Rx.merge([status, alerts])).autoConnect();
      _status = LastStream(merged);
      _nativeStatusSubscription = merged.listen(_managedStatus.add);
    }

    // Start the core first — the server certificate only exists after setup.
    portFront = await _grpcPort(1, fixedPortFront);
    if (!await _serverUp(portFront)) {
      final setupResult = await methodChannel.invokeMethod<dynamic>('setup', {
        'baseDir': directories.baseDir.path,
        'workingDir': directories.workingDir.path,
        'tempDir': directories.tempDir.path,
        'grpcPort': fixedPortFront,
        'mode': mode,
        'debug': debug,
      });
      _applyNativeStatusPayload(setupResult);
      portFront = await _grpcPort(1, fixedPortFront);
      if (portFront <= 0 || !await waitUntilPort(portFront, true, null)) {
        return 'failed to start foreground gRPC';
      }
    } else if (Platform.isIOS) {
      // Fg core already up (e.g. resume); still reload NE status so a live tunnel is mirrored.
      final syncResult = await methodChannel.invokeMethod<dynamic>('setup_vpn');
      _applyNativeStatusPayload(syncResult);
    }

    try {
      _credentials = await _buildCredentials();
    } catch (e, st) {
      loggy.error('mTLS credentials failed', e, st);
      return 'mTLS setup failed: $e';
    }

    // Probe that the channel works before replacing clients.
    final helloChannel = ClientChannel(
      '127.0.0.1',
      port: portFront,
      options: ChannelOptions(credentials: _credentials),
    );
    try {
      final helloClient = HelloClient(helloChannel);
      final res = await helloClient.sayHello(HelloRequest(name: 'test'));
      loggy.info(res.toString());
    } catch (e, st) {
      loggy.error('gRPC hello failed', e, st);
      await helloChannel.shutdown();
      return 'gRPC hello failed: $e';
    } finally {
      unawaited(helloChannel.shutdown());
    }

    // setup runs again every time the app is resumed. The channels it replaces
    // used to stay open until their idle timeout, so each resume left one more
    // connection to the VPN extension, which has a tight memory cap on iOS.
    final previousChannels = [_fgChannel, _bgChannel];
    _fgChannel = ClientChannel(
      '127.0.0.1',
      port: portFront,
      options: ChannelOptions(credentials: _credentials),
    );
    _bgChannel = ClientChannel(
      '127.0.0.1',
      port: portBack,
      options: ChannelOptions(credentials: _credentials),
    );
    fgClient = CoreClient(_fgChannel!);
    bgClient = CoreClient(_bgChannel!);
    for (final channel in previousChannels) {
      unawaited(channel?.shutdown());
    }

    // Tunnel can outlive the Flutter process; treat a live bg port as available.
    portBack = await _grpcPort(2, fixedPortBack);
    if (portBack > 0 && portBack != fixedPortBack) _replaceBgChannel();
    if (await _serverUp(portBack)) {
      _isBgClientAvailable = true;
    }
    return '';
  }

  /// A channel to the VPN service's control server on [portBack], which may have changed.
  void _replaceBgChannel() {
    final previous = _bgChannel;
    _bgChannel = ClientChannel('127.0.0.1', port: portBack, options: ChannelOptions(credentials: _credentials));
    bgClient = CoreClient(_bgChannel!);
    unawaited(previous?.shutdown());
  }

  void _applyNativeStatusPayload(dynamic payload) {
    if (payload is! Map) return;
    try {
      _managedStatus.add(CoreStatus.fromEvent(Map<String, dynamic>.from(payload)));
    } catch (e) {
      loggy.warning('native status payload: $e');
    }
  }

  Future<ChannelCredentials> _buildCredentials() async {
    if (!_useMtls) {
      return const ChannelCredentials.insecure();
    }

    final serverCert = await methodChannel.invokeMethod<Uint8List>('get_grpc_server_public_key');
    if (serverCert == null || serverCert.isEmpty) {
      throw StateError('empty gRPC server certificate');
    }

    final mtls = MTLSChannelCredentials.fromPem(
      serverCertificatePem: serverCert,
      clientCertificatePem: _identity.certificatePem,
      clientPrivateKeyPem: _identity.privateKeyPem,
    );
    // nothing is passed to the platform: the core and the platform service read the same identity
    // from the private storage
    return mtls;
  }

  @override
  Future<CoreStatus> setupBackground(String path, String name) async {
    // Stop any previous VPN gRPC server. A stuck port is logged but start is
    // still attempted — Android waits out Stopping before Mobile.setup.
    if (!await stop()) {
      loggy.warning('previous background core still closing; starting anyway');
    }
    _status.clean();
    await methodChannel.invokeMethod('start', {
      'path': path,
      'name': name,
      'grpcPort': fixedPortBack,
      'startBg': true,
      'debug': _debug,
    });

    _isBgClientAvailable = true;
    loggy.info('Waiting for starting core');
    final waitingSince = DateTime.now();
    // The reply to "start" only means the service was asked to start; whether it did arrives
    // later on the status stream. Wait for the first status that settles it: up, or stopped
    // with a reason. On timeout the port check below decides.
    try {
      final res = await _status.get(
        timeout: const Duration(seconds: 20),
        where: (status) => switch (status) {
          // the platform service is up: the core's own status takes over from here
          CoreStarted() || CoreWaiting() || CoreNoAvailableProxies() || CoreHotReloading() => true,
          CoreStopped(:final alert) => alert != null,
          _ => false,
        },
      );
      if (res is CoreStopped) return res;
    } on TimeoutException {
      loggy.warning('no start status from the service in 20 s');
    }
    loggy.info('Waiting for starting core finished after ${DateTime.now().difference(waitingSince).inMilliseconds}ms');

    // the VPN service's control server took a free port this time
    final port = await _grpcPort(2, fixedPortBack);
    if (port > 0 && port != portBack) {
      portBack = port;
      _replaceBgChannel();
    }
    if (portBack <= 0 || !await waitUntilPort(portBack, true, null)) {
      await stopMethodChannel();
      return const CoreStatus.stopped(alert: CoreAlert.startService, message: 'starting background core...');
    }

    return const CoreStarted();
  }

  @override
  Future<bool> stop() async {
    // Always ask the platform to stop: on iOS the tunnel can be up while the
    // extension gRPC port is unreachable (new app process / mTLS key), and
    // skipping disconnect left the VPN stuck in Settings.
    // MethodChannel stop already waits until the VPN service reports Stopped
    // (after Mobile.close), so only briefly poll the gRPC port.
    await stopMethodChannel();
    // the hardened core reports 0 once its VPN-service server is closed: nothing to probe then
    if (await _hardened()) portBack = await _grpcPort(2, fixedPortBack);
    if (!await _serverUp(portBack)) {
      _isBgClientAvailable = false;
      return true;
    }
    if (!await waitUntilPort(portBack, false, null)) {
      loggy.warning('background port $portBack still open after stop');
      // Platform stop finished; do not leave Disconnecting forever (#2395).
      _isBgClientAvailable = false;
      return true;
    }

    _isBgClientAvailable = false;
    return true;
  }

  Future stopMethodChannel() async {
    await methodChannel.invokeMethod('stop');
  }

  @override
  Future<bool> isBgClientAvailable() async {
    return _isBgClientAvailable;
  }

  @override
  bool get hasVpnProfile => true;

  @override
  Future<bool> resetTunnel() async {
    await methodChannel.invokeMethod('reset');
    return true;
  }

  @override
  Future<bool> isActiveFg() => _serverUp(portFront);

  @override
  Future<bool> isActiveBg() => _serverUp(portBack);
}

Future<bool> waitUntilPort(
  int portNumber,
  bool isOpen,
  Future Function()? callFunctionAfterEachFail, {
  int maxTry = 10,
}) async {
  for (var i = 0; i < maxTry; i++) {
    if (await isPortOpen('127.0.0.1', portNumber) == isOpen) {
      return true;
    }
    if (callFunctionAfterEachFail != null) {
      await callFunctionAfterEachFail();
    }

    await Future.delayed(const Duration(milliseconds: 200));
  }
  return false;
}

Future<bool> isPortOpen(String host, int port, {Duration timeout = const Duration(milliseconds: 300)}) async {
  try {
    final socket = await Socket.connect(host, port, timeout: timeout);
    await socket.close();
    return true;
  } on SocketException catch (_) {
    return false;
  } catch (_) {
    return false;
  }
}

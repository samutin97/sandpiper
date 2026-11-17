import 'dart:convert';
import 'dart:io';

import 'package:grpc/grpc.dart';
import 'package:hiddify/hiddifycore/core_interface/mtls_channel_cred.dart';
import 'package:path/path.dart' as p;

/// What the desktop app, its core and the VPN service must agree on: the names of the programs and
/// the service, and where the service keeps its secret and its address.
///
/// The core has the same values in hiddify-core/v2/hcore/vpnservice/names.go; the test
/// test/hiddifycore/service_names_test.dart compares both (and the Windows installer, the CMake
/// install list and the macOS controller with them).
abstract final class ServiceNames {
  // Windows: the launchers beside the app (the core's Makefile builds them under these names)
  static const windowsCli = 'SandpiperCore.exe';
  static const windowsAdmin = 'SandpiperAdmin.exe';
  static const windowsEngine = 'SandpiperCoreEngine.exe';
  // Linux: the launcher of the core, in the app's folder
  static const linuxCli = 'HiddifyCli';

  // Windows and Linux: the VPN service, never upstream Hiddify's (HiddifyAdminBG, ProgramData\Hiddify)
  static const serviceName = 'SandpiperAdminBG';
  static const windowsDataFolder = 'Sandpiper';
  static const windowsDataSubfolder = 'AdminBgService';
  static const linuxDataDir = '/var/lib/sandpiper-admin-bgservice';

  // macOS keeps upstream's label, folder and fixed port until the macOS app is renamed
  static const darwinServiceName = 'HiddifyAdminBG';
  static const darwinDataDir = '/Library/Application Support/Hiddify/AdminBgService/data';
  static const darwinServicePort = 18420;

  // the files in the service's folder
  static const secretFile = 'control.secret';
  static const endpointFile = 'control.endpoint';
  static const buildStampFile = 'build.id';

  // overrides of the folder (tests), as the core reads them
  static const dataDirEnv = 'HIDDIFY_ADMIN_BG_DATA';
  static const legacyDataDirEnv = 'HIDDIFY_TUNNEL_DATA';

  /// The service's folder on [operatingSystem] (Dart's names: windows, linux, macos).
  static String dataDir({String? operatingSystem, Map<String, String>? environment}) {
    final os = operatingSystem ?? Platform.operatingSystem;
    final env = environment ?? Platform.environment;
    final override = env[dataDirEnv] ?? '';
    if (override.isNotEmpty) return override;
    final legacy = env[legacyDataDirEnv] ?? '';
    if (legacy.isNotEmpty) return legacy;
    switch (os) {
      case 'windows':
        final base = env['PROGRAMDATA'] ?? '';
        return p.windows.join(base.isEmpty ? r'C:\ProgramData' : base, windowsDataFolder, windowsDataSubfolder);
      case 'macos':
        return darwinDataDir;
      default:
        return linuxDataDir;
    }
  }

  static String _inDataDir(String file, String? operatingSystem, Map<String, String>? environment) {
    final os = operatingSystem ?? Platform.operatingSystem;
    final context = os == 'windows' ? p.windows : p.posix;
    return context.join(dataDir(operatingSystem: os, environment: environment), file);
  }

  static String secretPath({String? operatingSystem, Map<String, String>? environment}) =>
      _inDataDir(secretFile, operatingSystem, environment);

  static String endpointPath({String? operatingSystem, Map<String, String>? environment}) =>
      _inDataDir(endpointFile, operatingSystem, environment);

  /// The console launcher the VPN service's commands go through.
  static String cliName({String? operatingSystem}) =>
      (operatingSystem ?? Platform.operatingSystem) == 'windows' ? windowsCli : linuxCli;
}

/// Where the VPN service listens and the certificate it presents: what the installed service
/// publishes at each start in [ServiceNames.endpointFile] (a free port, and a certificate whose key
/// stays in its memory), or what the AppImage's service prints. Only that certificate is trusted:
/// a program that took the port of a service that stopped never gets the control secret.
class ServiceEndpoint {
  const ServiceEndpoint({required this.host, required this.port, this.certificatePem});

  final String host;
  final int port;
  final String? certificatePem;

  @override
  String toString() => host.contains(':') ? '[$host]:$port' : '$host:$port';

  /// An address such as 127.0.0.1:41234 or [::1]:41234: a loopback IP and a port, else null.
  static ({String host, int port})? parseAddress(String address) {
    final colon = address.lastIndexOf(':');
    if (colon <= 0) return null;
    var host = address.substring(0, colon);
    if (host.startsWith('[') && host.endsWith(']')) host = host.substring(1, host.length - 1);
    final port = int.tryParse(address.substring(colon + 1));
    final ip = InternetAddress.tryParse(host);
    if (port == null || port <= 0 || port > 65535 || ip == null || !ip.isLoopback) return null;
    return (host: host, port: port);
  }

  /// The endpoint file's content (JSON: address, certificate).
  factory ServiceEndpoint.parse(String content) {
    final Object? json;
    try {
      json = jsonDecode(content);
    } on FormatException catch (e) {
      throw FormatException("the VPN service's endpoint file is invalid: ${e.message}");
    }
    if (json is! Map<String, dynamic>) throw const FormatException("the VPN service's endpoint file is invalid");
    final address = parseAddress(json['address'] as String? ?? '');
    if (address == null) throw FormatException("the VPN service's address is invalid: ${json['address']}");
    final certificate = json['certificate'] as String? ?? '';
    // never without one: the service always serves TLS, and the file is written only by it
    if (!certificate.contains('-----BEGIN CERTIFICATE-----')) {
      throw const FormatException("the VPN service published no certificate");
    }
    return ServiceEndpoint(host: address.host, port: address.port, certificatePem: certificate);
  }

  /// The endpoint the installed service published, or null when it has published none (not running).
  static Future<ServiceEndpoint?> read({String? path}) async {
    final file = File(path ?? ServiceNames.endpointPath());
    if (!await file.exists()) return null;
    return ServiceEndpoint.parse(await file.readAsString());
  }

  /// TLS that accepts only [certificatePem].
  ChannelCredentials get credentials {
    final certificate = certificatePem;
    if (certificate == null) throw StateError('The VPN service published no certificate.');
    return PinnedTlsChannelCredentials.fromPem(certificate);
  }

  ClientChannel channel() => ClientChannel(host, port: port, options: ChannelOptions(credentials: credentials));
}

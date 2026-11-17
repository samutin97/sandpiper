import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/hiddifycore/core_interface/service_names.dart';

/// The core's side of the names (hiddify-core/v2/hcore/vpnservice/names.go), present when the core
/// submodule is checked out.
const _goNames = 'hiddify-core/v2/hcore/vpnservice/names.go';

/// `Name = "value"` and `Name = 123` lines of a Go const block.
Map<String, String> _goConstants(String source) {
  final constants = <String, String>{};
  for (final match in RegExp(r'^\s*([A-Z]\w*)\s*=\s*(?:"([^"]*)"|(\d+))\s*(?://.*)?$', multiLine: true).allMatches(source)) {
    constants[match.group(1)!] = match.group(2) ?? match.group(3)!;
  }
  return constants;
}

void main() {
  // W4-03: the app, the core and the VPN service took the service's folder from different places
  // (the app upstream Hiddify's, the core the fork's); now each has one place, and this compares them.
  test(
    'the app and the core agree on the VPN service names and folder',
    () {
      final go = _goConstants(File(_goNames).readAsStringSync());
      final dart = <String, Object>{
        'WindowsCLI': ServiceNames.windowsCli,
        'WindowsAdmin': ServiceNames.windowsAdmin,
        'WindowsEngine': ServiceNames.windowsEngine,
        'LinuxCLI': ServiceNames.linuxCli,
        'ServiceName': ServiceNames.serviceName,
        'WindowsDataFolder': ServiceNames.windowsDataFolder,
        'WindowsDataSubfolder': ServiceNames.windowsDataSubfolder,
        'LinuxDataDir': ServiceNames.linuxDataDir,
        'DarwinServiceName': ServiceNames.darwinServiceName,
        'DarwinDataDir': ServiceNames.darwinDataDir,
        'DarwinServicePort': ServiceNames.darwinServicePort,
        'SecretFile': ServiceNames.secretFile,
        'EndpointFile': ServiceNames.endpointFile,
        'BuildStampFile': ServiceNames.buildStampFile,
        'DataDirEnv': ServiceNames.dataDirEnv,
        'LegacyDataDirEnv': ServiceNames.legacyDataDirEnv,
      };
      for (final entry in dart.entries) {
        expect(go[entry.key], '${entry.value}', reason: '${entry.key} differs between names.go and service_names.dart');
      }
    },
    skip: File(_goNames).existsSync() ? false : 'the core submodule is not checked out',
  );

  test("the service folder is the fork's on Windows and Linux", () {
    expect(
      ServiceNames.secretPath(operatingSystem: 'windows', environment: {'PROGRAMDATA': r'D:\Data'}),
      r'D:\Data\Sandpiper\AdminBgService\control.secret',
    );
    expect(ServiceNames.secretPath(operatingSystem: 'windows', environment: {}), r'C:\ProgramData\Sandpiper\AdminBgService\control.secret');
    expect(ServiceNames.endpointPath(operatingSystem: 'linux', environment: {}), '/var/lib/sandpiper-admin-bgservice/control.endpoint');
    expect(ServiceNames.secretPath(operatingSystem: 'linux', environment: {ServiceNames.dataDirEnv: '/tmp/svc'}), '/tmp/svc/control.secret');
    for (final os in ['windows', 'linux']) {
      expect(ServiceNames.dataDir(operatingSystem: os, environment: {}).toLowerCase(), isNot(contains('hiddify')));
    }
    expect(ServiceNames.cliName(operatingSystem: 'windows'), 'SandpiperCore.exe');
  });

  // the other places that name the service and the programs, in this repository
  test('the installer, the bundle and the macOS controller use the same names', () {
    final installer = File('windows/packaging/exe/inno_setup.sas').readAsStringSync();
    expect(installer, contains("ADMIN_SERVICE = '${ServiceNames.serviceName}'"));
    final cmake = File('windows/CMakeLists.txt').readAsStringSync();
    for (final program in [ServiceNames.windowsCli, ServiceNames.windowsAdmin, ServiceNames.windowsEngine]) {
      expect(cmake, contains(program));
    }
    final workflow = File('.github/workflows/sandpiper-release.yml').readAsStringSync();
    for (final program in [ServiceNames.windowsCli, ServiceNames.windowsAdmin, ServiceNames.windowsEngine]) {
      expect(workflow, contains(program));
    }
    final swift = File('macos/Runner/AdminBgServiceController.swift').readAsStringSync();
    expect(swift, contains('${ServiceNames.darwinDataDir}/${ServiceNames.secretFile}'));
    expect(swift, contains('servicePort: UInt16 = ${ServiceNames.darwinServicePort}'));
  });

  // W4-01: no fixed port of the app's own cores, nor of the Windows/Linux service, in the app's code
  test('the desktop core interfaces name no fixed control port', () {
    for (final path in [
      'lib/hiddifycore/core_interface/core_interface_desktop.dart',
      'lib/hiddifycore/core_interface/core_interface_desktop_tun.dart',
      'lib/hiddifycore/core_interface/core_interface_macos.dart',
      'lib/hiddifycore/core_interface/appimage_service.dart',
    ]) {
      final code = File(path).readAsLinesSync().where((line) => !line.trimLeft().startsWith('//')).join('\n');
      for (final port in ['17078', '17079', '17080', '18020', '18021', '18420']) {
        expect(code, isNot(contains(port)), reason: '$path names $port');
      }
    }
  });
}

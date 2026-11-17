import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/directories/directories_provider.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/directories.dart';
import 'package:hiddify/core/model/region.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/profile/data/profile_parser.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/singbox/model/singbox_config_enum.dart';
import 'package:hiddify/utils/platform_utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The fork's defaults for a new install in Russia (task item 12, M-03, M-08, H-06).
void main() {
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    container = ProviderContainer();
    await container.read(sharedPreferencesProvider.future);
  });

  tearDown(() => container.dispose());

  test('Russia by default: its sites go directly', () {
    expect(container.read(ConfigOptions.region), Region.ru);
  });

  test('the fastest proxy, kept, tested every 30 minutes over one HTTPS address', () {
    expect(container.read(ConfigOptions.defaultProxy), DefaultProxy.lowest);
    expect(container.read(ConfigOptions.urlTestInterval), const Duration(minutes: 30));
    final url = container.read(ConfigOptions.connectionTestUrl);
    expect(url, startsWith('https://'));
    expect(url, ConfigOptions.defaultConnectionTestUrl);
    expect(ProfileParser.keepTopDefault, 3);
  });

  test('direct sites: the system resolver; server names: DoH by IP, Yandex only an option', () {
    expect(container.read(ConfigOptions.directDnsAddress), 'local');
    final servers = container.read(ConfigOptions.serverDnsAddress).split(',');
    expect(servers, ['https://1.1.1.1/dns-query', 'https://9.9.9.9/dns-query', 'https://8.8.8.8/dns-query']);
    expect(container.read(ConfigOptions.serverDnsAddress), isNot(contains('yandex')));
  });

  test('IPv6 stays inside the tunnel by default (ipv4 only), no mux, no TLS tricks', () {
    expect(container.read(ConfigOptions.ipv6Mode), IPv6Mode.ipv4Only);
    expect(container.read(ConfigOptions.enableMux), isFalse);
    expect(container.read(ConfigOptions.enableTlsFragment), isFalse);
  });

  test('nothing open or shared by default; logs at warn', () {
    expect(container.read(ConfigOptions.serviceMode), ServiceMode.tun);
    expect(container.read(ConfigOptions.allowConnectionFromLan), isFalse);
    expect(container.read(ConfigOptions.localProxyInVpn), isFalse);
    expect(container.read(ConfigOptions.localProxyUdp), isFalse);
    expect(container.read(ConfigOptions.logLevel).name, 'warn');
  });

  // B-03: on the desktop the local port asks for the user and password by default (phones always do)
  test('the local proxy asks for the password by default on the desktop', () {
    expect(container.read(ConfigOptions.localProxyAuth), PlatformUtils.isDesktop);
  });

  test('no automatic IP lookups, subscriptions only through the tunnel', () {
    expect(container.read(Preferences.autoCheckIp), isFalse);
    expect(container.read(Preferences.updateProfilesWithoutTunnel), isFalse);
  });

  test('the options sent to the core ask for no port, no lookups and no insecure TLS', () async {
    final dir = await Directory.systemTemp.createTemp('fork_defaults');
    addTearDown(() => dir.delete(recursive: true));
    final withRules = ProviderContainer(
      overrides: [
        appDirectoriesProvider.overrideWith(() => _Directories(dir)),
        translationsProvider.overrideWith((ref) => AppLocale.en.build()),
      ],
    );
    addTearDown(withRules.dispose);
    await withRules.read(appDirectoriesProvider.future);
    await withRules.read(sharedPreferencesProvider.future);
    await withRules.read(translationsProvider.future);
    final json = withRules.read(ConfigOptions.singboxConfigOptions).toJson();
    expect(json['region'], 'ru');
    expect(json['default-proxy'], 'lowest');
    expect(json['clash-api-listen'], isFalse);
    expect(json['ipinfo'], isFalse);
    expect(json['allow-insecure'], isFalse);
    expect(json['expand-subscription-links'], isFalse);
    expect(json['local-proxy-udp'], isFalse);
    expect(json['local-proxy-in-vpn'], isFalse);
    // phones always; the desktop by default (the system proxy's own listener stays without one)
    expect(json['local-proxy-auth'], isTrue);
    expect(json['allow-connection-from-lan'], isFalse);
    expect(json['monitoring-workers'], 2);
    expect(json['retest-on-network-change'], 'selected');
    expect(json['udp-endpoints-in-auto'], isFalse);
    expect(json['direct-dns-address'], 'local');
    expect(json['server-dns-address'], ConfigOptions.defaultServerDns);
  });
}

class _Directories extends AppDirectories {
  _Directories(this.dir);

  final Directory dir;

  @override
  Future<Directories> build() async => (baseDir: dir, workingDir: dir, tempDir: dir);
}

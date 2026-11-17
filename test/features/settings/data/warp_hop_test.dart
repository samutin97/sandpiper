import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/preferences/preferences_migration.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/singbox/model/singbox_config_enum.dart';
import 'package:hiddify/singbox/model/singbox_config_option.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

// The JSON keys of hiddify-core's ChainWarpScannerOptions, ChainWarpMasqueOptions and
// ChainWarpAwgOptions (v2/config/chain.go): a key the core does not read would change nothing.
const _scannerKeys = {'search-noise', 'max-rtt', 'timeout', 'count', 'concurrency', 'ports', 'cidrs'};
const _masqueKeys = {
  'vhttp',
  'server-name',
  'use-ipv6',
  'udp-timeout',
  'udp-keepalive',
  'udp-initial-packet-size',
  'reconnect-delay',
  'tls-insecure',
  'tls-fragment',
  'tls-fragment-fallback-delay',
  'tls-record-fragment',
  'ech-enabled',
  'ech-config',
  'ech-query-server-name',
};
const _awgKeys = {'jc', 'jmin', 'jmax', 's1', 's2', 's3', 's4', 'h1', 'h2', 'h3', 'h4', 'i1', 'i2', 'i3', 'i4', 'i5'};

Future<SharedPreferences> _migrated(Map<String, Object> stored) async {
  SharedPreferences.setMockInitialValues({...stored, PreferencesMigration.versionKey: 2});
  final preferences = await SharedPreferences.getInstance();
  await PreferencesMigration(sharedPreferences: preferences).migrate();
  return preferences;
}

void main() {
  test("the WARP blocks speak the core's keys", () {
    expect(const SingboxWarpScannerOption().toJson().keys.toSet(), _scannerKeys);
    expect(const SingboxWarpMasqueOption().toJson().keys.toSet(), _masqueKeys);
    expect(const SingboxWarpAwgOption().toJson().keys.toSet(), _awgKeys);
  });

  test('a block that changes nothing is not sent, so the core keeps its defaults', () {
    expect(const SingboxWarpScannerOption().orNull, isNull);
    expect(const SingboxWarpMasqueOption().orNull, isNull);
    expect(const SingboxWarpAwgOption().orNull, isNull);
    expect(const SingboxWarpMasqueOption(vhttp: 'h2').orNull, isNotNull);

    final hop = const SingboxExtraSecurityWarpOption(
      licenseKey: '',
      endpoint: WarpEndpointSource.custom,
      cleanIp: '162.159.192.1',
      cleanPort: 2408,
      masque: SingboxWarpMasqueOption(echEnabled: true),
    ).toJson();
    expect(hop['endpoint'], 'custom');
    expect(hop['clean-ip'], '162.159.192.1');
    expect(hop['clean-port'], 2408);
    expect(hop['awg'], isNull);
    final sent = jsonDecode(jsonEncode(hop)) as Map<String, dynamic>;
    expect((sent['masque'] as Map)['ech-enabled'], true);
  });

  test("extra security, behind the user's pick, never scans", () {
    expect(WarpEndpointSource.of(detour: true), [WarpEndpointSource.profile, WarpEndpointSource.custom]);
    expect(WarpEndpointSource.of(detour: false), WarpEndpointSource.values);
  });

  group('an older clean IP', () {
    test('that was an address becomes the custom endpoint, and stays', () async {
      final preferences = await _migrated({'unblocker-warp-clean-ip': '162.159.192.1'});
      expect(preferences.getString('unblocker-warp-endpoint'), 'custom');
      expect(preferences.getString('unblocker-warp-clean-ip'), '162.159.192.1');
    });

    test('that was a word for a scan becomes the scan', () async {
      final preferences = await _migrated({'unblocker-warp-clean-ip': 'auto'});
      expect(preferences.getString('unblocker-warp-endpoint'), 'scan');
      expect(preferences.containsKey('unblocker-warp-clean-ip'), isFalse);
    });

    test('never set leaves the default, and a source already set stays', () async {
      expect((await _migrated({})).containsKey('unblocker-warp-endpoint'), isFalse);
      final set = await _migrated({'unblocker-warp-clean-ip': '1.1.1.1', 'unblocker-warp-endpoint': 'profile'});
      expect(set.getString('unblocker-warp-endpoint'), 'profile');
    });
  });

  test('a stored block that no longer reads is the default again', () async {
    SharedPreferences.setMockInitialValues({
      'unblocker-warp-masque': '{not json',
      'unblocker-warp-scanner': jsonEncode({
        'max-rtt': 800,
        'ports': [443, 2408],
      }),
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(sharedPreferencesProvider.future);
    expect(container.read(ConfigOptions.unblockerWarpMasque), const SingboxWarpMasqueOption());
    expect(
      container.read(ConfigOptions.unblockerWarpScanner),
      const SingboxWarpScannerOption(maxRtt: 800, ports: [443, 2408]),
    );
  });

  // the fork (ForkVersion1Migration): the hardened core asks for a secret of 16 characters at least
  test('every install gets a proxy secret of 16 characters, a long one set is kept', () async {
    final fresh = await _migrated({});
    expect(fresh.getString('lan_sharing_password'), matches(RegExp(r'^\w{4}-\w{4}-\w{4}-\w{4}$')));
    final kept = await _migrated({'lan_sharing_password': 'mine-long-enough-secret'});
    expect(kept.getString('lan_sharing_password'), 'mine-long-enough-secret');
    final short = await _migrated({'lan_sharing_password': 'mine-secret'});
    expect(short.getString('lan_sharing_password')!.replaceAll('-', '').length, greaterThanOrEqualTo(16));
  });

  test('every install gets its own proxy user, a random local port and a TUN address seed', () async {
    final a = await _migrated({});
    final b = await _migrated({});
    expect(a.getString('local-proxy-username'), matches(RegExp(r'^[a-z]{8}$')));
    expect(a.getInt('mixed-port'), allOf(greaterThanOrEqualTo(20000), lessThan(60000)));
    expect(a.getString('tun-address-seed'), matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(a.getString('tun-address-seed'), isNot(b.getString('tun-address-seed')));
    final kept = await _migrated({'mixed-port': 2080});
    expect(kept.getInt('mixed-port'), 2080);
    final moved = await _migrated({'mixed-port': 12334});
    expect(moved.getInt('mixed-port'), isNot(12334));
  });

  // the fork (ForkVersion2Migration, B-05): no Clash API on the well-known 16756
  test('every install gets a random Clash API port apart from the local proxy, a chosen one is kept', () async {
    final fresh = await _migrated({});
    expect(fresh.getInt('clash-api-port'), allOf(greaterThanOrEqualTo(20000), lessThan(60000)));
    expect(fresh.getInt('clash-api-port'), isNot(fresh.getInt('mixed-port')));
    final moved = await _migrated({'clash-api-port': 16756});
    expect(moved.getInt('clash-api-port'), isNot(16756));
    final kept = await _migrated({'clash-api-port': 9090});
    expect(kept.getInt('clash-api-port'), 9090);
  });
}

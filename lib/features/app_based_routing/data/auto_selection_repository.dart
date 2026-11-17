import 'package:flutter/services.dart';
import 'package:hiddify/core/model/region.dart';
import 'package:hiddify/features/app_based_routing/model/per_app_proxy_mode.dart';
import 'package:hiddify/utils/utils.dart';

enum AutoSelectionResult { success, failure, notFound }

abstract interface class AutoSelectionRepository {
  Future<(Set<String>?, AutoSelectionResult)> getByAppProxyMode({required AppProxyMode mode, required Region region});
}

/// The lists of apps for split tunnelling, built into the app (assets/app_lists/). Upstream
/// downloaded them once a day from github.com/hiddify/Android-GFW-Apps and applied them without
/// asking (M-06): whoever controls that repository decided which apps go around the VPN.
class AutoSelectionRepositoryImpl with AppLogger implements AutoSelectionRepository {
  AutoSelectionRepositoryImpl();

  static String assetFor(AppProxyMode mode, Region region) => switch (mode) {
    AppProxyMode.include => 'assets/app_lists/proxy_${region.name}.txt',
    AppProxyMode.exclude => 'assets/app_lists/direct_${region.name}.txt',
  };

  @override
  Future<(Set<String>?, AutoSelectionResult)> getByAppProxyMode({
    required AppProxyMode mode,
    required Region region,
  }) async {
    final String text;
    try {
      text = await rootBundle.loadString(assetFor(mode, region));
    } catch (_) {
      return (null, AutoSelectionResult.notFound);
    }
    final list = parseAppList(text);
    if (list.isEmpty) return (null, AutoSelectionResult.notFound);
    return (list, AutoSelectionResult.success);
  }

  /// One package name per line, or `prefix:<start>`; `#` starts a comment.
  static Set<String> parseAppList(String text) => text
      .split('\n')
      .map((line) => line.split('#').first.trim())
      .where((line) => line.isNotEmpty)
      .toSet();
}

/// Package names that are never taken by a prefix: VPN and proxy clients (they must not be kept out
/// of the VPN by accident, and some are the user's other clients) and browsers (a browser is the
/// user's to choose).
final _neverByPrefix = RegExp(
  'vpn|proxy|xray|v2ray|amnezia|hiddify|byedpi|zapret|wireguard|clash|sing-?box|nekobox|outline|psiphon|lantern|'
  r'strongswan|shadowsocks|browser|(^|\.)(tor|orbot)(\.|$)',
  caseSensitive: false,
);

/// The apps of [entries] (names and `prefix:` lines, see [AutoSelectionRepositoryImpl.parseAppList])
/// for this device: the names as they are (Android ignores one not installed), and each installed app
/// a prefix takes, except VPN/proxy clients and browsers.
///
/// Upstream's own list for Russia was the single line `ru.*`: a pattern neither the app nor
/// VpnService.Builder.addDisallowedApplication expands, so it kept no app out of the VPN.
Set<String> expandAppList(Set<String> entries, Set<String> installed) {
  final names = <String>{};
  final prefixes = <String>[];
  for (final entry in entries) {
    if (entry.startsWith('prefix:')) {
      final prefix = entry.substring('prefix:'.length).trim();
      if (prefix.length >= 3) prefixes.add(prefix);
    } else if (!entry.contains('*')) {
      names.add(entry);
    }
  }
  for (final pkg in installed) {
    if (prefixes.any(pkg.startsWith) && !_neverByPrefix.hasMatch(pkg)) names.add(pkg);
  }
  return names;
}

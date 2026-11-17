import 'package:hiddify/core/http_client/app_traffic.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/utils/platform_utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// The core's local proxy of this session, with the credentials the app sent the core (H-03, H-06),
/// or null when the core asks for none: then it is not known to be the core's.
///
/// The hardened core asks for local-proxy-username and the secret; the official 5.9.8 core for the
/// user "hiddify" and the secret, while local-proxy-auth is on (always on phones).
LocalProxyRoute? localProxyRoute(Ref ref, {required bool hardenedCore}) {
  final password = ref.read(ConfigOptions.lanSharingPassword);
  if (password.isEmpty) return null;
  final port = ref.read(ConfigOptions.mixedPort);
  if (hardenedCore) {
    final username = ref.read(ConfigOptions.localProxyUsername);
    if (username.isEmpty) return null;
    return LocalProxyRoute(port: port, username: username, password: password);
  }
  if (!PlatformUtils.isMobile && !ref.read(ConfigOptions.localProxyAuth)) return null;
  return LocalProxyRoute(port: port, username: 'hiddify', password: password);
}

/// The user name other apps and devices give the local and LAN proxy.
String localProxyUser(WidgetRef ref, {required bool hardenedCore}) {
  final username = ref.read(ConfigOptions.localProxyUsername);
  return hardenedCore && username.isNotEmpty ? username : 'hiddify';
}

import 'package:hiddify/core/http_client/app_traffic.dart';
import 'package:hiddify/core/http_client/http_client_provider.dart';
import 'package:hiddify/core/http_client/local_proxy_route.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/singbox/model/singbox_config_enum.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Whether the app's own requests go through the tunnel right now (H-02).
bool appTrafficTunneled(Ref ref) => ref.read(httpClientProvider).trafficState.tunneled;

/// [appTrafficTunneled], taken from the connection itself when the HTTP client has not heard of it
/// yet (D-03: a deep link that starts or resumes the app reached the import dialog before the first
/// connection status, which then said the VPN was not connected while it was).
Future<bool> appTrafficTunneledNow(Ref ref) async {
  if (appTrafficTunneled(ref)) return true;
  final ConnectionStatus status;
  try {
    status = await ref.read(connectionNotifierProvider.future).timeout(const Duration(seconds: 3));
  } catch (_) {
    return false;
  }
  final connected = status is Connected || status is NoAvailableProxies || status is HotReloading;
  if (!connected) return false;
  final mode = ref.read(ConfigOptions.serviceMode);
  final vpnMode = mode == ServiceMode.tun || mode == ServiceMode.router;
  if (vpnMode) return appInsideOwnVpn();
  return localProxyRoute(ref, hardenedCore: await hardenedCore()) != null;
}

/// Before a request the user asked for (a subscription update) leaves the device outside the tunnel:
/// asks once, unless the user allowed such updates. True when the request may go.
Future<bool> confirmRequestOutsideTunnel(Ref ref) async {
  if (ref.read(Preferences.updateProfilesWithoutTunnel) || await appTrafficTunneledNow(ref)) return true;
  final t = ref.read(translationsProvider).requireValue;
  return ref
      .read(dialogNotifierProvider.notifier)
      .showConfirmation(title: t.fork.direct.title, message: t.fork.direct.message);
}

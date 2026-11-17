import 'dart:io';

import 'package:hiddify/hiddifycore/core_interface/core_interface_mobile.dart';

/// The core's local proxy, as this session set it up: its port and credentials (H-03).
///
/// The app sends its own requests through a local proxy only when it knows the proxy is the core's,
/// because the core asked for exactly these credentials. A port that merely answers on 127.0.0.1 may
/// be any app's: before, the app sent its subscription updates to whatever listened on the mixed port.
class LocalProxyRoute {
  const LocalProxyRoute({required this.port, required this.username, required this.password});

  final int port;
  final String username;
  final String password;

  /// For [HttpClient.findProxy]. dart:io reads `user:password@host:port` without decoding it, so
  /// the credentials must hold no `:` or `@`; [generateLocalProxyPassword] makes none.
  String get findProxyDirective => 'PROXY $username:$password@127.0.0.1:$port';

  @override
  bool operator ==(Object other) =>
      other is LocalProxyRoute && other.port == port && other.username == username && other.password == password;

  @override
  int get hashCode => Object.hash(port, username, password);
}

/// Where the app's own requests (subscriptions, the IP check) go right now (H-02, H-03).
class AppTrafficState {
  const AppTrafficState({this.connected = false, this.vpnMode = false, this.appInsideVpn = false, this.proxy});

  /// The core runs and the connection is up.
  final bool connected;

  /// VPN (TUN) mode, not proxy mode.
  final bool vpnMode;

  /// Whether the VPN carries this app's own traffic: on Android only with a core that protects its
  /// own sockets (see CoreCaps.kt); elsewhere the system routes the app through its VPN like any app.
  final bool appInsideVpn;

  /// In proxy mode, the core's local proxy of this session; null when not known.
  final LocalProxyRoute? proxy;

  /// Through the tunnel: the provider sees only the VPN server, not where the request goes.
  bool get tunneled => connected && (vpnMode ? appInsideVpn : proxy != null);

  /// The proxy to send requests through, if any: in VPN mode the system routes them.
  LocalProxyRoute? get activeProxy => connected && !vpnMode ? proxy : null;

  @override
  bool operator ==(Object other) =>
      other is AppTrafficState &&
      other.connected == connected &&
      other.vpnMode == vpnMode &&
      other.appInsideVpn == appInsideVpn &&
      other.proxy == proxy;

  @override
  int get hashCode => Object.hash(connected, vpnMode, appInsideVpn, proxy);

  @override
  String toString() =>
      'AppTrafficState(connected: $connected, vpnMode: $vpnMode, appInsideVpn: $appInsideVpn, proxy: ${proxy != null})';
}

/// Whether the VPN, once up, carries this app's own requests. Android asks the platform side, which
/// knows the core; elsewhere the app is never kept out of its own VPN.
Future<bool> appInsideOwnVpn() async {
  if (!Platform.isAndroid) return true;
  try {
    return await CoreInterfaceMobile.methodChannel.invokeMethod<bool>('app_traffic_tunneled') ?? false;
  } catch (_) {
    return false;
  }
}

bool? _hardenedCore;

/// Outside Android the build says which core it bundles: `--dart-define=core_hardened=true` for the
/// fork's hardened core (the Makefile adds it with CORE_HARDENED=1, as the release workflow does for
/// Windows and macOS); a desktop build with the official core leaves it unset.
const _builtWithHardenedCore = bool.fromEnvironment('core_hardened');

/// Whether the core is the fork's hardened one (on Android it reports its control port; elsewhere
/// the build says so). The hardened core asks the local proxy for local-proxy-username, the official
/// one for "hiddify".
Future<bool> hardenedCore() async {
  if (_hardenedCore != null) return _hardenedCore!;
  if (!Platform.isAndroid) return _hardenedCore = _builtWithHardenedCore;
  try {
    return _hardenedCore = await CoreInterfaceMobile.methodChannel.invokeMethod<bool>('core_hardened') ?? false;
  } catch (_) {
    return _hardenedCore = false;
  }
}

/// [hardenedCore] once it is known, false before (outside Android it is known from the build).
bool get hardenedCoreKnown => _hardenedCore ?? (!Platform.isAndroid && _builtWithHardenedCore);

/// Thrown for a request that must not leave the device outside the tunnel (the IP check), while
/// there is none.
class NoTunnelException implements Exception {
  const NoTunnelException();

  @override
  String toString() => 'NoTunnelException: not connected through the tunnel';
}

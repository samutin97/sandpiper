import 'package:hiddify/hiddifycore/core_interface/core_interface_mobile.dart';
import 'package:hiddify/utils/platform_utils.dart';

/// L-06: FLAG_SECURE on the app's window (Android).
Future<void> setSecureScreen(bool secure) async {
  if (!PlatformUtils.isAndroid) return;
  try {
    await CoreInterfaceMobile.platformChannel.invokeMethod<bool>('set_secure_screen', secure);
  } catch (_) {}
}

/// The system VPN settings, where Always-on VPN and "Block connections without VPN" are turned on
/// (the system kill switch). False when they could not be opened.
Future<bool> openSystemVpnSettings() async {
  if (!PlatformUtils.isAndroid) return false;
  try {
    return await CoreInterfaceMobile.platformChannel.invokeMethod<bool>('open_vpn_settings') ?? false;
  } catch (_) {
    return false;
  }
}

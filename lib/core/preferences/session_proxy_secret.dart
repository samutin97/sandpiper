import 'package:hiddify/core/utils/proxy_secret.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The preference that keeps the local proxy's password from one launch to the next.
const persistentProxySecretKey = 'proxy-secret-persistent';

/// W4-04: on the desktop the local proxy's password is made anew at every launch, so a copy of the
/// settings (a backup, a synced profile, the portable folder) is useless once the app has restarted.
/// Not when the user keeps one ([persistentProxySecretKey]: set by hand, or for a program that keeps
/// using the proxy with it), nor while the proxy is shared on the local network, whose devices were
/// given it once (QR code). Phones keep theirs: their proxy is shared that way only.
///
/// It is not left out of the settings altogether: the core gets it in the settings it keeps, and the
/// app reaches its own proxy with it. Returns whether a new one was made.
Future<bool> renewSessionProxySecret(SharedPreferences preferences, {required bool desktop}) async {
  if (!desktop) return false;
  if (preferences.getBool(persistentProxySecretKey) ?? false) return false;
  if (preferences.getBool('allow-connection-from-lan') ?? false) return false;
  // 16 characters at least, as the hardened core asks of local-proxy-password
  await preferences.setString('lan_sharing_password', generateProxySecret(length: 16));
  return true;
}

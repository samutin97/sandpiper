import 'dart:io';
import 'dart:math';

/// The ports the app picks at random for the core's loopback listeners (the local proxy, the Clash
/// API) come from [localPortMin, localPortMin + localPortSpan), and each is checked by binding it on
/// 127.0.0.1 when it is picked (D9-01): Windows reserves ranges of ports (Hyper-V, WSL; `netsh int
/// ipv4 show excludedportrange protocol=tcp`), where a bind is refused, and moves them at a reboot;
/// another program may hold a port as well.
const localPortMin = 20000;
const localPortSpan = 40000;

/// How many random ports [pickLocalPort] tries before it gives the last one unchecked.
const localPortAttempts = 50;

typedef LocalPortProbe = Future<bool> Function(int port);

/// Whether [port] can be bound on 127.0.0.1 now (TCP); the socket is closed at once.
Future<bool> loopbackPortFree(int port) async {
  try {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    await socket.close();
    return true;
  } on SocketException {
    return false;
  }
}

/// A random port that binds on 127.0.0.1 now and is not in [avoid]. When none did in
/// [localPortAttempts] tries (no loopback at all), the last one tried, as before the check.
Future<int> pickLocalPort({Set<int> avoid = const {}, Random? random, LocalPortProbe probe = loopbackPortFree}) async {
  random ??= Random.secure();
  var candidate = localPortMin + random.nextInt(localPortSpan);
  for (var i = 0; i < localPortAttempts; i++) {
    candidate = localPortMin + random.nextInt(localPortSpan);
    if (avoid.contains(candidate)) continue;
    if (await probe(candidate)) return candidate;
  }
  return candidate;
}

/// The port of a loopback listener the core could not open, from its start error: Go words it
/// "listen tcp 127.0.0.1:51803: bind: An attempt was made to access a socket in a way forbidden by
/// its access permissions." (a port Windows reserves), "…bind: Only one usage of each socket address
/// …" (Windows) or "…bind: address already in use" (elsewhere), in English on every system. Null
/// for any other error.
int? failedLocalBind(String message) {
  final match = RegExp(r'listen (?:tcp|udp)[46]? \S*:(\d+): bind: ').firstMatch(message);
  return match == null ? null : int.tryParse(match.group(1)!);
}

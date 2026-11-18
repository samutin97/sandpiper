import 'package:hiddify/core/utils/local_port.dart';

/// D9-01: the port of a loopback listener the app picked at random and saved (the local proxy, the
/// Clash API) can stop being usable: Windows reserves ranges of ports and moves them at a reboot
/// (a bind there is refused), and another program may take it. The core then fails to start, and
/// every later start failed the same way, as the port stays saved. [failedKey] recognises such a
/// failure, and [replace] picks and saves a new free port for it; the connection repository then
/// starts again once.
class LocalPortRepair {
  LocalPortRepair({
    required this.ports,
    required this.repairable,
    required this.save,
    this.pick = pickLocalPort,
    this.onRepaired,
  });

  /// Every local port the app sets, by preference key: a new port keeps off all of them.
  final Map<String, int> Function() ports;

  /// The keys of [ports] the app picked at random, and may pick again.
  final Set<String> repairable;

  final Future<void> Function(String key, int port) save;
  final Future<int> Function({Set<int> avoid}) pick;
  final void Function(String key, int from, int to)? onRepaired;

  /// The key of the repairable port a failed start could not open, from its error, or null.
  String? failedKey(String message) {
    final port = failedLocalBind(message);
    if (port == null) return null;
    for (final MapEntry(:key, :value) in ports().entries) {
      if (value == port && repairable.contains(key)) return key;
    }
    return null;
  }

  /// Picks a new free port for [key], keeping off every other local port, and saves it.
  Future<int> replace(String key) async {
    final current = ports();
    final next = await pick(avoid: current.values.toSet());
    await save(key, next);
    onRepaired?.call(key, current[key] ?? 0, next);
    return next;
  }
}

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/connection/data/local_port_repair.dart';

void main() {
  late Map<String, int> ports;
  late List<String> saved;
  late LocalPortRepair repair;

  setUp(() {
    ports = {"mixed-port": 51803, "clash-api-port": 40001, "lan-sharing-port": 12338};
    saved = [];
    repair = LocalPortRepair(
      ports: () => ports,
      repairable: const {"mixed-port", "clash-api-port"},
      save: (key, port) async {
        saved.add("$key=$port");
        ports[key] = port;
      },
      pick: ({Set<int> avoid = const {}}) async {
        expect(avoid, containsAll([51803, 40001, 12338]));
        return 30001;
      },
    );
  });

  test('recognises a failure to open a port the app picked', () {
    expect(
      repair.failedKey(
        "startService - start inbound: start inbound/mixed[mixed-in127.0.0.1]: listen tcp 127.0.0.1:51803: "
        "bind: An attempt was made to access a socket in a way forbidden by its access permissions.",
      ),
      "mixed-port",
    );
    expect(repair.failedKey("listen tcp 127.0.0.1:40001: bind: address already in use"), "clash-api-port");
    // a port the user set, and other failures
    expect(repair.failedKey("listen tcp 0.0.0.0:12338: bind: address already in use"), isNull);
    expect(repair.failedKey("start inbound/tun[tun-in]: configure tun interface: Access is denied."), isNull);
  });

  test('replaces a port with a free one that keeps off the others, and saves it', () async {
    expect(await repair.replace("mixed-port"), 30001);
    expect(saved, ["mixed-port=30001"]);
  });
}

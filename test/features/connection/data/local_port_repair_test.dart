import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hiddify/features/connection/data/local_port_repair.dart';

const _refused =
    "startFailed - start service: start inbound/mixed[mixed-in]: listen tcp 127.0.0.1:51803: bind: "
    "An attempt was made to access a socket in a way forbidden by its access permissions.";

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

  // D9-01: the saved local proxy port fell into a range Windows reserves, and every start failed
  // on it. The start now gets a new port, saved, and runs once more.
  test('a start that cannot open the local proxy port gets a new one and runs again', () async {
    final starts = <int>[];
    final result = await repair.run<String, Unit>(() async {
      starts.add(ports["mixed-port"]!);
      return starts.length == 1 ? left(_refused) : right(unit);
    }, (failure) => failure);
    expect(result.isRight(), isTrue);
    expect(starts, [51803, 30001]);
    expect(saved, ["mixed-port=30001"]);
  });

  test('runs again once only', () async {
    var starts = 0;
    final result = await repair.run<String, Unit>(() async {
      starts++;
      return left(_refused.replaceAll("51803", "${ports["mixed-port"]}"));
    }, (failure) => failure);
    expect(result.isLeft(), isTrue);
    expect(starts, 2);
    expect(saved, ["mixed-port=30001"]);
  });

  test('other failures, and ports the user set, are not repaired', () async {
    for (final failure in [
      "start inbound/tun[tun-in]: configure tun interface: Access is denied.",
      "listen tcp 0.0.0.0:12338: bind: address already in use",
    ]) {
      var starts = 0;
      final result = await repair.run<String, Unit>(() async {
        starts++;
        return left(failure);
      }, (failure) => failure);
      expect(result.getLeft().toNullable(), failure);
      expect(starts, 1);
    }
    expect(saved, isEmpty);
    expect(repair.failedKey(_refused), "mixed-port");
    expect(repair.failedKey("listen tcp 127.0.0.1:40001: bind: address already in use"), "clash-api-port");
  });
}

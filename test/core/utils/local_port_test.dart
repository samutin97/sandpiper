import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/utils/local_port.dart';
import 'package:logging/logging.dart';

void main() {
  group('pickLocalPort', () {
    test('skips ports that do not bind and ports to avoid', () async {
      final tried = <int>[];
      final refused = <int>{};
      final port = await pickLocalPort(
        random: Random(1),
        avoid: {},
        probe: (port) async {
          tried.add(port);
          // the first two refuse, as ports in a range Windows reserves
          if (tried.length <= 2) {
            refused.add(port);
            return false;
          }
          return true;
        },
      );
      expect(tried.length, 3);
      expect(refused.contains(port), isFalse);
      expect(port, inInclusiveRange(localPortMin, localPortMin + localPortSpan - 1));

      final avoided = await pickLocalPort(random: Random(1), probe: (_) async => true);
      final other = await pickLocalPort(random: Random(1), avoid: {avoided}, probe: (_) async => true);
      expect(other, isNot(avoided));
    });

    test('a port in use does not bind', () async {
      final held = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      expect(await loopbackPortFree(held.port), isFalse);
      final port = held.port;
      await held.close();
      expect(await loopbackPortFree(port), isTrue);
    });
  });

  group('failedLocalBind', () {
    test('reads the port of a listener the core could not open', () {
      expect(
        failedLocalBind(
          "startFailed - start service: start inbound/mixed[mixed-in]: listen tcp 127.0.0.1:51803: bind: "
          "An attempt was made to access a socket in a way forbidden by its access permissions.",
        ),
        51803,
      );
      expect(
        failedLocalBind(
          "listen tcp 127.0.0.1:20480: bind: Only one usage of each socket address (protocol/network address/port) "
          "is normally permitted.",
        ),
        20480,
      );
      expect(failedLocalBind("listen tcp4 [::1]:31000: bind: address already in use"), 31000);
    });

    test('is null for other errors', () {
      expect(failedLocalBind("start inbound/tun[tun-in]: configure tun interface: Access is denied."), isNull);
      expect(failedLocalBind("dial tcp 192.0.2.1:443: connect: connection refused"), isNull);
      expect(failedLocalBind(""), isNull);
    });
  });
  group('softenHandledBind', () {
    const line = "start inbound/mixed[mixed-in]: listen tcp 127.0.0.1:51803: bind: address already in use";

    test('a fatal line the repair handles is a warning, marked as handled', () {
      final softened = softenHandledBind(level: Level.SHOUT, message: line, handled: (_) => true);
      expect(softened.level, Level.WARNING);
      expect(softened.message, startsWith(line));
      expect(softened.message, endsWith('(handled: the local port is replaced)'));
      expect(softenHandledBind(level: Level.SEVERE, message: line, handled: (_) => true).level, Level.WARNING);
    });

    test('a line that is not handled, and any other level, stay as they are', () {
      expect(softenHandledBind(level: Level.SHOUT, message: line, handled: (_) => false).level, Level.SHOUT);
      expect(softenHandledBind(level: Level.SHOUT, message: line, handled: null).level, Level.SHOUT);
      final info = softenHandledBind(level: Level.INFO, message: line, handled: (_) => true);
      expect((info.level, info.message), (Level.INFO, line));
    });
  });
}

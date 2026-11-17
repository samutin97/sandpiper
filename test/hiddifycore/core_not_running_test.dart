import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:hiddify/hiddifycore/core_interface/core_interface.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore_service.pbgrpc.dart';

void main() {
  // An import with a core that did not start said "LateInitializationError: Field 'fgClient' has not
  // been initialized"; it says why the core is not running now.
  test('a call without a core says the core is not running, and why', () {
    final core = CoreInterface();
    expect(core.isInitialized(), isFalse);
    expect(() => core.fgClient, throwsA(isA<CoreNotRunning>()));
    expect(() => core.bgClient, throwsA(isA<CoreNotRunning>()));
    expect(const CoreNotRunning().toString(), 'The core is not running');

    core.setupFailure = 'listen tcp 127.0.0.1:1: bind: address already in use';
    expect(
      () => core.fgClient,
      throwsA(
        isA<CoreNotRunning>().having(
          (error) => error.toString(),
          'message',
          'The core is not running: listen tcp 127.0.0.1:1: bind: address already in use',
        ),
      ),
    );
  });

  test('the clients once set up', () async {
    final core = CoreInterface();
    final channel = ClientChannel('127.0.0.1', port: 1, options: const ChannelOptions(credentials: ChannelCredentials.insecure()));
    addTearDown(channel.shutdown);
    final client = CoreClient(channel);
    core.fgClient = core.bgClient = client;
    expect(core.isInitialized(), isTrue);
    expect(core.isSingleChannel(), isTrue);
    expect(identical(core.fgClient, client), isTrue);
  });
}

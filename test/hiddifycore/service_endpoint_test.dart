import 'dart:convert';

import 'package:basic_utils/basic_utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:hiddify/hiddifycore/core_interface/core_interface_desktop.dart';
import 'package:hiddify/hiddifycore/core_interface/core_process.dart';
import 'package:hiddify/hiddifycore/core_interface/service_names.dart';
import 'package:hiddify/hiddifycore/generated/v2/hello/hello.pb.dart';
import 'package:hiddify/hiddifycore/generated/v2/hello/hello_service.pbgrpc.dart';

/// A self-signed server certificate for 127.0.0.1 and its key, as the VPN service makes one.
({String certificate, String key}) _serverIdentity() {
  final pair = CryptoUtils.generateRSAKeyPair();
  final privateKey = pair.privateKey as RSAPrivateKey;
  final publicKey = pair.publicKey as RSAPublicKey;
  final csr = X509Utils.generateRsaCsrPem({'CN': '127.0.0.1'}, privateKey, publicKey, san: ['127.0.0.1', 'localhost']);
  final certificate = X509Utils.generateSelfSignedCertificate(
    privateKey,
    csr,
    30,
    sans: ['127.0.0.1', 'localhost'],
    extKeyUsage: [ExtendedKeyUsage.SERVER_AUTH],
  );
  return (certificate: certificate, key: CryptoUtils.encodeRSAPrivateKeyToPem(privateKey));
}

class _Hello extends HelloServiceBase {
  @override
  Future<HelloResponse> sayHello(ServiceCall call, HelloRequest request) async =>
      HelloResponse(message: 'hello ${request.name}');

  @override
  Stream<HelloResponse> sayHelloStream(ServiceCall call, Stream<HelloRequest> request) =>
      request.map((each) => HelloResponse(message: 'hello ${each.name}'));
}

void main() {
  group('ServiceEndpoint', () {
    test('reads the endpoint the service publishes', () {
      final identity = _serverIdentity();
      final endpoint = ServiceEndpoint.parse(
        jsonEncode({'address': '127.0.0.1:41234', 'certificate': identity.certificate}),
      );
      expect(endpoint.host, '127.0.0.1');
      expect(endpoint.port, 41234);
      expect(endpoint.certificatePem, identity.certificate);
      expect(ServiceEndpoint.parse(jsonEncode({'address': '[::1]:5', 'certificate': identity.certificate})).host, '::1');
    });

    test('refuses an endpoint that is not a loopback port with a certificate', () {
      final certificate = _serverIdentity().certificate;
      for (final content in [
        jsonEncode({'address': '0.0.0.0:41234', 'certificate': certificate}),
        jsonEncode({'address': '192.0.2.1:41234', 'certificate': certificate}),
        jsonEncode({'address': 'localhost:41234', 'certificate': certificate}),
        jsonEncode({'address': '127.0.0.1:0', 'certificate': certificate}),
        jsonEncode({'address': '127.0.0.1', 'certificate': certificate}),
        // no TLS: the service always serves it, so an endpoint without it is not the service's
        jsonEncode({'address': '127.0.0.1:41234'}),
        jsonEncode({'address': '127.0.0.1:41234', 'certificate': 'not a certificate'}),
        '{',
        '[]',
      ]) {
        expect(() => ServiceEndpoint.parse(content), throwsFormatException, reason: content);
      }
    });

    test('a client reaches only the server with the published certificate', () async {
      final service = _serverIdentity();
      final other = _serverIdentity();
      final server = Server.create(services: [_Hello()]);
      await server.serve(
        address: '127.0.0.1',
        port: 0,
        security: ServerTlsCredentials(
          certificate: utf8.encode(service.certificate),
          privateKey: utf8.encode(service.key),
        ),
      );
      addTearDown(server.shutdown);
      final port = server.port!;

      final trusted = ServiceEndpoint(host: '127.0.0.1', port: port, certificatePem: service.certificate).channel();
      addTearDown(trusted.shutdown);
      final reply = await HelloClient(trusted).sayHello(HelloRequest(name: 'app'));
      expect(reply.message, 'hello app');

      // the same port with another certificate: not the service, nothing is sent
      final impostor = ServiceEndpoint(host: '127.0.0.1', port: port, certificatePem: other.certificate).channel();
      addTearDown(impostor.shutdown);
      await expectLater(
        HelloClient(impostor).sayHello(HelloRequest(name: 'app'), options: CallOptions(timeout: const Duration(seconds: 5))),
        throwsA(isA<GrpcError>()),
      );
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('free ports (W4-01)', () {
    test('the port of the address the core reports', () {
      expect(CoreProcess.loopbackPort('127.0.0.1:41234'), 41234);
      expect(CoreProcess.loopbackPort('[::1]:41234'), 41234);
      expect(CoreProcess.loopbackPort('127.0.0.1:0'), isNull);
      expect(CoreProcess.loopbackPort('0.0.0.0:41234'), isNull);
      expect(CoreProcess.loopbackPort(''), isNull);
      expect(CoreProcess.loopbackPort('unix:/run/core.sock'), isNull);
    });

    test('a taken port is told apart from other errors on every desktop', () {
      expect(
        CoreInterfaceDesktop.isPortTaken(
          'listen tcp 127.0.0.1:17078: bind: Only one usage of each socket address (protocol/network address/port) is normally permitted.',
        ),
        isTrue,
      );
      expect(CoreInterfaceDesktop.isPortTaken('listen tcp 127.0.0.1:17078: bind: address already in use'), isTrue);
      expect(CoreInterfaceDesktop.isPortTaken('the core exited (1) before it was ready'), isFalse);
    });
  });
}

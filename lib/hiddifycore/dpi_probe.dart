import 'package:grpc/grpc.dart';
import 'package:protobuf/protobuf.dart';

/// The hardened core's path diagnostic (`Core.DpiProbe`, core-app-interface.md 8.2): TCP, TLS, then
/// 64 KiB down (and up) to a server, to tell a cut ClientHello or the "16 KB" freeze from a server
/// that is down. Run only when the user asks; the core runs one at a time.
///
/// The Dart stubs of the core's protos are not regenerated in the fork (no protoc plugin in the
/// build); this one call is encoded by hand, by the field numbers of v2/hcore/hcore.proto.
class DpiProbeParams {
  const DpiProbeParams({
    required this.host,
    this.port = 443,
    this.serverName = '',
    this.path = '/',
    this.uploadPath = '',
    this.upload = false,
    this.attempts = 1,
    this.timeoutMs = 8000,
    this.classicalKeyShare = false,
  });

  final String host;
  final int port;
  final String serverName;
  final String path;

  /// The path the upload POSTs to (field 12 of the hardened core); empty: [path].
  final String uploadPath;
  final bool upload;
  final int attempts;
  final int timeoutMs;
  final bool classicalKeyShare;

  List<int> encode() {
    final w = CodedBufferWriter();
    if (host.isNotEmpty) w.writeField(1, PbFieldType.OS, host);
    if (port != 0) w.writeField(2, PbFieldType.OU3, port);
    if (serverName.isNotEmpty) w.writeField(3, PbFieldType.OS, serverName);
    if (path.isNotEmpty) w.writeField(5, PbFieldType.OS, path);
    if (upload) w.writeField(6, PbFieldType.OB, true);
    if (attempts != 0) w.writeField(7, PbFieldType.OU3, attempts);
    if (timeoutMs != 0) w.writeField(8, PbFieldType.OU3, timeoutMs);
    if (classicalKeyShare) w.writeField(11, PbFieldType.OS, 'classical');
    if (uploadPath.isNotEmpty) w.writeField(12, PbFieldType.OS, uploadPath);
    return w.toBuffer();
  }
}

class DpiProbeStage {
  const DpiProbeStage({this.name = '', this.outcome = '', this.bytes = 0, this.millis = 0, this.detail = ''});

  final String name;
  final String outcome;
  final int bytes;
  final int millis;
  final String detail;

  factory DpiProbeStage.decode(List<int> buffer) {
    var name = '';
    var outcome = '';
    var detail = '';
    var bytes = 0;
    var millis = 0;
    final r = CodedBufferReader(buffer);
    while (!r.isAtEnd()) {
      final tag = r.readTag();
      switch (tag >> 3) {
        case 1:
          name = r.readString();
        case 2:
          outcome = r.readString();
        case 3:
          bytes = r.readInt64().toInt();
        case 4:
          millis = r.readInt64().toInt();
        case 5:
          detail = r.readString();
        default:
          _skip(r, tag);
      }
    }
    return DpiProbeStage(name: name, outcome: outcome, bytes: bytes, millis: millis, detail: detail);
  }
}

class DpiProbeResult {
  const DpiProbeResult({this.outcome = '', this.stages = const [], this.connections = 0});

  /// ok, tcp_timeout, tcp_reset, tls_timeout, tls_reset, tls_error, freeze_16k, stall, reset, busy,
  /// error, budget
  final String outcome;
  final List<DpiProbeStage> stages;
  final int connections;

  factory DpiProbeResult.decode(List<int> buffer) {
    var outcome = '';
    var connections = 0;
    final stages = <DpiProbeStage>[];
    final r = CodedBufferReader(buffer);
    while (!r.isAtEnd()) {
      final tag = r.readTag();
      switch (tag >> 3) {
        case 1:
          outcome = r.readString();
        case 2:
          stages.add(DpiProbeStage.decode(r.readBytes()));
        case 3:
          connections = r.readUint32();
        default:
          _skip(r, tag);
      }
    }
    return DpiProbeResult(outcome: outcome, stages: stages, connections: connections);
  }
}

void _skip(CodedBufferReader r, int tag) {
  switch (tag & 7) {
    case 0:
      r.readUint64();
    case 1:
      r.readFixed64();
    case 2:
      r.readBytes();
    case 5:
      r.readFixed32();
    default:
      throw const FormatException('unknown wire type');
  }
}

final _method = ClientMethod<DpiProbeParams, DpiProbeResult>(
  '/hcore.Core/DpiProbe',
  (params) => params.encode(),
  DpiProbeResult.decode,
);

/// Runs the probe on [client]'s core (the app's own, which dials directly, outside the VPN). Fails
/// with UNIMPLEMENTED on a core without it (the official one).
Future<DpiProbeResult> runDpiProbe(Client client, DpiProbeParams params) =>
    client.$createUnaryCall(_method, params, options: CallOptions(timeout: const Duration(seconds: 90)));

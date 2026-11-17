import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/features/settings/widget/dpi_probe_dialog.dart';
import 'package:hiddify/hiddifycore/dpi_probe.dart';
import 'package:protobuf/protobuf.dart';

/// The hand-written codec of Core.DpiProbe, by the field numbers of hiddify-core v2/hcore/hcore.proto.
void main() {
  test('the request carries host, port, SNI, path, upload, attempts, timeout and key share', () {
    final bytes = const DpiProbeParams(
      host: 'example.com',
      port: 8443,
      serverName: 'sni.example.com',
      path: '/__probe/131072',
      upload: true,
      classicalKeyShare: true,
    ).encode();
    final r = CodedBufferReader(bytes);
    final fields = <int, Object>{};
    while (!r.isAtEnd()) {
      final tag = r.readTag();
      final field = tag >> 3;
      fields[field] = switch (field) {
        1 || 3 || 5 || 11 => r.readString(),
        2 || 7 || 8 => r.readUint32(),
        6 => r.readBool(),
        _ => throw StateError('unexpected field $field'),
      };
    }
    expect(fields, {
      1: 'example.com',
      2: 8443,
      3: 'sni.example.com',
      5: '/__probe/131072',
      6: true,
      7: 1,
      8: 8000,
      11: 'classical',
    });
  });

  test('the upload path goes as field 12 only when given (D-08)', () {
    List<int> fieldsOf(List<int> bytes) {
      final r = CodedBufferReader(bytes);
      final numbers = <int>[];
      while (!r.isAtEnd()) {
        final tag = r.readTag();
        numbers.add(tag >> 3);
        r.skipField(tag);
      }
      return numbers;
    }

    const base = DpiProbeParams(host: 'example.com', path: '/files/64k.bin', upload: true);
    expect(fieldsOf(base.encode()), isNot(contains(12)));
    final bytes = const DpiProbeParams(
      host: 'example.com',
      path: '/files/64k.bin',
      uploadPath: '/upload',
      upload: true,
    ).encode();
    final r = CodedBufferReader(bytes);
    String? upload;
    while (!r.isAtEnd()) {
      final tag = r.readTag();
      if (tag >> 3 == 12) {
        upload = r.readString();
      } else {
        r.skipField(tag);
      }
    }
    expect(upload, '/upload');
  });

  test('the dialog tells the verdict, how far, the time and the connections (D-08)', () {
    final t = AppLocale.en.buildSync();
    const freeze = DpiProbeResult(
      outcome: 'freeze_16k',
      connections: 2,
      stages: [
        DpiProbeStage(name: 'tcp', outcome: 'ok', millis: 120),
        DpiProbeStage(name: 'download', outcome: 'freeze_16k', bytes: 16384, millis: 8000),
      ],
    );
    final text = describeDpiProbe(t, freeze, 9.25);
    expect(text, contains('froze at 16 KB'));
    expect(text, contains('9.3 s'));
    expect(text, contains('2 connections'));
    expect(text, contains('download: freeze_16k, 16.0 KB, 8000 ms'));

    const ok = DpiProbeResult(outcome: 'ok', connections: 3);
    expect(describeDpiProbe(t, ok, 2), startsWith('OK'));
    const reset = DpiProbeResult(outcome: 'tls_reset', connections: 1);
    expect(describeDpiProbe(t, reset, 1), contains('TLS reset'));
    // an outcome of a newer core is shown as it is
    expect(describeDpiProbe(t, const DpiProbeResult(outcome: 'new_kind'), 1), startsWith('new_kind'));
  });

  test('the response gives the outcome, the stages and the connections', () {
    final stage = CodedBufferWriter()
      ..writeField(1, PbFieldType.OS, 'download')
      ..writeField(2, PbFieldType.OS, 'freeze_16k')
      ..writeField(3, PbFieldType.O6, Int64(16384))
      ..writeField(4, PbFieldType.O6, Int64(8000));
    final w = CodedBufferWriter()
      ..writeField(1, PbFieldType.OS, 'freeze_16k')
      ..writeField(2, PbFieldType.OY, stage.toBuffer())
      ..writeField(3, PbFieldType.OU3, 2)
      ..writeField(9, PbFieldType.OS, 'a field of a newer core');
    final result = DpiProbeResult.decode(w.toBuffer());
    expect(result.outcome, 'freeze_16k');
    expect(result.connections, 2);
    expect(result.stages.single.name, 'download');
    expect(result.stages.single.outcome, 'freeze_16k');
    expect(result.stages.single.bytes, 16384);
    expect(result.stages.single.millis, 8000);
  });
}

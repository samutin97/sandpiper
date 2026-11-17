import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/profile/data/profile_parser.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/model/profile_probe.dart';

void main() {
  group('profile-probe header', () {
    test('reads every field', () {
      final probe = ProfileProbe.parse('get=/files/sample.bin;size=131072;post=/upload;up=262144');
      expect(probe, const ProfileProbe(getPath: '/files/sample.bin', size: 131072, postPath: '/upload', uploadLimit: 262144));
      expect(probe!.canUpload, isTrue);
      expect(probe.encode(), 'get=/files/sample.bin;size=131072;post=/upload;up=262144');
    });

    test('needs only get; spaces, an empty pair and unknown keys do not matter', () {
      expect(ProfileProbe.parse(' get = /a/b.png ; ; later=1'), const ProfileProbe(getPath: '/a/b.png'));
      expect(ProfileProbe.parse('get=/a/b.png')!.canUpload, isFalse);
    });

    test('the upload runs only with a post path that takes 64 KiB', () {
      expect(ProfileProbe.parse('get=/a;post=/b')!.canUpload, isTrue);
      expect(ProfileProbe.parse('get=/a;post=/b;up=65536')!.canUpload, isTrue);
      expect(ProfileProbe.parse('get=/a;post=/b;up=65535')!.canUpload, isFalse);
      // up without post is no limit of anything
      expect(ProfileProbe.parse('get=/a;up=262144'), const ProfileProbe(getPath: '/a'));
    });

    test('a list of one value is that value; of more, nothing', () {
      expect(ProfileProbe.parse(['get=/a']), const ProfileProbe(getPath: '/a'));
      expect(ProfileProbe.parse(['get=/a', 'get=/b']), isNull);
    });

    for (final bad in <Object?>[
      null,
      '',
      42,
      'size=100000',
      'get=',
      'get=a/b',
      'get=//example.com/a',
      'get=https://example.com/a',
      'get=/a?b=1',
      'get=/a#b',
      'get=/a b',
      r'get=/a\b',
      'get=/a/../b',
      'get=/./a',
      'get=/a/..',
      'get=/%zz',
      'get=/a\tb',
      'get=/ä',
      'get=/a;get=/b',
      'get=/a;size=32767',
      'get=/a;size=1073741825',
      'get=/a;size=0200000',
      'get=/a;size=-1',
      'get=/a;size=2e5',
      'get=/a;post=upload',
      'get=/a;post=/b;up=0',
      'get=/a;post=/b;up=big',
      'garbage',
      '=/a',
    ]) {
      test('ignores ${bad is String ? '"$bad"' : bad}', () => expect(ProfileProbe.parse(bad), isNull));
    }

    test('ignores a value or a path over the limits', () {
      expect(ProfileProbe.parse('get=/${'a' * 255}'), isNotNull);
      expect(ProfileProbe.parse('get=/${'a' * 256}'), isNull);
      expect(ProfileProbe.parse('get=/a;x=${'b' * 600}'), isNull);
    });

    test('takes percent-escapes, dots inside names, tildes and dashes', () {
      expect(ProfileProbe.parse('get=/~user/a-b_c.d%20e/f..g'), isNotNull);
    });
  });

  group('the subscription keeps the probe', () {
    test('from the HTTP answer, in its canonical form', () {
      final headers = ProfileParser.populateHeaders(
        content: '',
        remoteHeaders: {'profile-probe': ' get=/a.bin ; post=/b ;size=40000;future=1'},
      ).getOrElse((_) => throw StateError('no headers'));
      expect(headers['profile-probe'], 'get=/a.bin;size=40000;post=/b');
    });

    test('never from the text of a subscription', () {
      final headers = ProfileParser.populateHeaders(
        content: '#profile-probe: get=/a.bin\n#profile-title: Name\nvless://x',
      ).getOrElse((_) => throw StateError('no headers'));
      expect(headers.containsKey('profile-probe'), isFalse);
      expect(headers['profile-title'], 'Name');
    });

    test('garbage is dropped without failing the subscription', () {
      final headers = ProfileParser.populateHeaders(
        content: '',
        remoteHeaders: {'profile-probe': 'get=https://example.com/a', 'profile-title': 'Name'},
      ).getOrElse((_) => throw StateError('no headers'));
      expect(headers.containsKey('profile-probe'), isFalse);
      expect(headers['profile-title'], 'Name');
    });

    test('is what the profile gives the path check, and never goes to the core', () {
      final profile = ProfileEntity.remote(
        id: 'id',
        active: true,
        name: 'n',
        url: 'https://example.com/s',
        lastUpdate: DateTime(2026),
        populatedHeaders: const {'profile-probe': 'get=/a.bin;post=/b;up=262144'},
      );
      expect(profile.probe, const ProfileProbe(getPath: '/a.bin', postPath: '/b', uploadLimit: 262144));
      expect(profile.profileOverride(), isNot(contains('probe')));
      expect(profile.copyWith(populatedHeaders: const {}).probe, isNull);
    });
  });
}

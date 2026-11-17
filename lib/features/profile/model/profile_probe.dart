import 'package:meta/meta.dart';

/// The path check's endpoints of a subscription's server, from the `profile-probe` header of the
/// subscription's HTTP answer. Kept with the profile (in its headers) and offered by the path check
/// (DpiProbe) when that profile is active; the user can still type others.
///
/// Header value (ASCII, at most [maxLength] characters): `key=value` pairs separated by `;`, spaces
/// around a pair, a key or a value ignored, keys in lower case:
///
///     profile-probe: get=/files/sample.bin;size=131072;post=/upload;up=262144
///
/// - `get` (required): the path of a file on the subscription's host that the check downloads (it asks
///   for the first 64 KiB with a `Range` header).
/// - `size` (optional): how many bytes that file has, from 32768 (the check needs more than ~25 KB to see
///   a transfer that stops at 16 KB) to 1 GiB.
/// - `post` (optional): the path on the same host that reads a POST body; without it the check does not
///   upload.
/// - `up` (optional, with `post`): the largest body that path takes, 1 byte to 1 GiB; under 65536 the
///   check does not upload (it sends 64 KiB).
///
/// A path is absolute on the subscription's host: `/` then at most 255 characters out of
/// `A-Z a-z 0-9 - . _ ~ /` and `%` with two hex digits; no `//` at its start, no `.` or `..` segment,
/// no query, fragment, scheme, host, backslash or space. A size is decimal digits without a sign or
/// leading zero. A header with a known key twice, a known key with a bad value, or no valid `get` is
/// ignored as a whole and silently (nothing is kept); keys this version does not know are skipped.
@immutable
class ProfileProbe {
  const ProfileProbe({required this.getPath, this.size, this.postPath, this.uploadLimit});

  static const headerName = 'profile-probe';
  static const maxLength = 512;
  static const maxPathLength = 256;
  static const minSize = 32768;
  static const maxSize = 1 << 30;

  /// What the check uploads, so the least a `post` path must take for the upload to run.
  static const uploadBytes = 65536;

  final String getPath;
  final int? size;
  final String? postPath;
  final int? uploadLimit;

  /// Whether the upload half of the check can run against this server.
  bool get canUpload => postPath != null && (uploadLimit == null || uploadLimit! >= uploadBytes);

  static final _path = RegExp(r'^/(?:[A-Za-z0-9\-._~/]|%[0-9A-Fa-f]{2})*$');
  static final _number = RegExp(r'^[1-9][0-9]{0,9}$');

  /// The probe of a header value, or null for anything that is not one (see the class).
  static ProfileProbe? parse(Object? value) {
    if (value is List) return value.length == 1 ? parse(value.first) : null;
    if (value is! String || value.isEmpty || value.length > maxLength) return null;
    if (value.codeUnits.any((c) => c < 0x20 || c > 0x7e)) return null;
    final known = <String, String>{};
    for (final pair in value.split(';')) {
      if (pair.trim().isEmpty) continue;
      final index = pair.indexOf('=');
      if (index <= 0) return null;
      final key = pair.substring(0, index).trim();
      final item = pair.substring(index + 1).trim();
      if (!const {'get', 'size', 'post', 'up'}.contains(key)) continue;
      if (known.containsKey(key)) return null;
      known[key] = item;
    }
    final getPath = known['get'];
    if (getPath == null || !isPath(getPath)) return null;
    int? size;
    if (known['size'] case final text?) {
      size = _size(text);
      if (size == null || size < minSize) return null;
    }
    String? postPath;
    if (known['post'] case final text?) {
      if (!isPath(text)) return null;
      postPath = text;
    }
    int? uploadLimit;
    if (known['up'] case final text?) {
      uploadLimit = _size(text);
      if (uploadLimit == null) return null;
      if (postPath == null) uploadLimit = null;
    }
    return ProfileProbe(getPath: getPath, size: size, postPath: postPath, uploadLimit: uploadLimit);
  }

  /// Whether [path] is a path the check may use on the subscription's host (see the class).
  static bool isPath(String path) {
    if (path.isEmpty || path.length > maxPathLength || !_path.hasMatch(path) || path.startsWith('//')) {
      return false;
    }
    return !path.split('/').any((segment) => segment == '.' || segment == '..');
  }

  static int? _size(String text) {
    if (!_number.hasMatch(text)) return null;
    final n = int.parse(text);
    return n <= maxSize ? n : null;
  }

  /// The canonical header value, what the profile keeps.
  String encode() => [
    'get=$getPath',
    if (size != null) 'size=$size',
    if (postPath != null) 'post=$postPath',
    if (uploadLimit != null) 'up=$uploadLimit',
  ].join(';');

  @override
  bool operator ==(Object other) =>
      other is ProfileProbe &&
      other.getPath == getPath &&
      other.size == size &&
      other.postPath == postPath &&
      other.uploadLimit == uploadLimit;

  @override
  int get hashCode => Object.hash(getPath, size, postPath, uploadLimit);

  @override
  String toString() => 'ProfileProbe(${encode()})';
}

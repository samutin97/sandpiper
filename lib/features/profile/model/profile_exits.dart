import 'dart:convert';

import 'package:meta/meta.dart';

/// The two ways out to the internet a subscription's server offers (the `profile-exits` header of
/// the subscription's HTTP answer): `main`, as the server is set up, and `warp`, the reserve for a
/// site that does not let the main address in. The server keeps them as two subscriptions, a pair;
/// each one says which it is and where the other is. The app shows them as one profile.
///
/// Header value (ASCII, at most [maxLength] characters): `key=value` pairs separated by `;`, spaces
/// around a pair, a key or a value ignored, keys and the two role names in any case:
///
///     profile-exits: v=1;cur=main;alt=warp;alt-url=aHR0cHM6Ly9leGFtcGxlLm9yZy9zdWIvd2FycA
///
/// - `v` (required): the version, only `1` is known.
/// - `cur` (required): what the subscription that sent the header is, `main` or `warp`.
/// - `alt` (required): what the other one is, the other of the two.
/// - `alt-url` (required): the other subscription's whole link, https, on the host of the subscription that sent
///   the header, in base64url without `=`.
///   It is a secret like any subscription link: the app never shows it nor writes it to a log.
///
/// A header with a known key twice, a version this app does not know, a key missing or with a value
/// that is not one of the above, or a link that is not an https one, is ignored as a whole (no pair,
/// no choice); keys this version does not know are skipped.
@immutable
class ProfileExits {
  const ProfileExits({required this.current, required this.alternative, required this.alternativeUrl});

  static const headerName = 'profile-exits';
  static const maxLength = 4096;
  static const maxUrlLength = 2048;
  static const version = 1;

  /// What the subscription that sent the header is.
  final ExitRole current;

  /// What the other subscription of the pair is.
  final ExitRole alternative;

  /// The other subscription's link: a secret.
  final String alternativeUrl;

  static final _urlText = RegExp(r'^[A-Za-z0-9_-]+$');

  /// The pair of a header value, or null for none: no header, or one that is not valid (see
  /// [parseVerdict] to tell them apart).
  static ProfileExits? parse(Object? value, {String? sourceUrl}) => parseVerdict(value, sourceUrl: sourceUrl).exits;

  /// The pair of a header value, and why there is none when there is none. [ExitsVerdict.absent]
  /// is no header at all; the others are a header that was dropped.
  ///
  /// With [sourceUrl], the link of the subscription whose answer carried the header, the pair's link
  /// must be on the same host (any case), port and scheme: an answer can not send the app to another
  /// host. Without it (a header already kept) there is no such check.
  static ExitsVerdict parseVerdict(Object? value, {String? sourceUrl}) {
    if (value == null) return const ExitsVerdict.absent();
    if (value is List) {
      return value.length == 1 ? parseVerdict(value.first, sourceUrl: sourceUrl) : const ExitsVerdict.invalid();
    }
    if (value is! String) return const ExitsVerdict.invalid();
    final text = value.trim();
    if (text.isEmpty) return const ExitsVerdict.absent();
    if (text.length > maxLength || text.codeUnits.any((c) => c < 0x20 || c > 0x7e)) {
      return const ExitsVerdict.invalid();
    }
    final known = <String, String>{};
    for (final pair in text.split(';')) {
      if (pair.trim().isEmpty) continue;
      final index = pair.indexOf('=');
      if (index <= 0) return const ExitsVerdict.invalid();
      final key = pair.substring(0, index).trim().toLowerCase();
      final item = pair.substring(index + 1).trim();
      if (!const {'v', 'cur', 'alt', 'alt-url'}.contains(key)) continue;
      if (known.containsKey(key)) return const ExitsVerdict.invalid();
      known[key] = item;
    }
    final v = known['v'];
    if (v == null) return const ExitsVerdict.invalid();
    if (v != '$version') return const ExitsVerdict.unknownVersion();
    final current = ExitRole.tryParse(known['cur']);
    final alternative = ExitRole.tryParse(known['alt']);
    if (current == null || alternative == null || current == alternative) return const ExitsVerdict.invalid();
    final url = decodeUrl(known['alt-url']);
    if (url == null || (sourceUrl != null && !sameOrigin(url, sourceUrl))) return const ExitsVerdict.invalid();
    return ExitsVerdict._(ProfileExits(current: current, alternative: alternative, alternativeUrl: url));
  }

  /// The link of a base64url text without padding, or null when it is not one, or not an https link.
  static String? decodeUrl(String? text) {
    if (text == null || text.isEmpty || !_urlText.hasMatch(text)) return null;
    final String url;
    try {
      url = utf8.decode(base64Url.decode(base64Url.normalize(text)));
    } on FormatException {
      return null;
    }
    return isSubscriptionUrl(url) ? url : null;
  }

  /// Whether [url] is on the host (any case), port and scheme of [source].
  static bool sameOrigin(String url, String source) {
    final a = Uri.tryParse(url.trim());
    final b = Uri.tryParse(source.trim());
    if (a == null || b == null || a.host.isEmpty || b.host.isEmpty) return false;
    return a.scheme.toLowerCase() == b.scheme.toLowerCase() &&
        a.host.toLowerCase() == b.host.toLowerCase() &&
        a.port == b.port;
  }

  /// Whether [url] is a link the app downloads a subscription from: https, a host, no blank or
  /// control character, not longer than [maxUrlLength].
  static bool isSubscriptionUrl(String url) {
    if (url.isEmpty || url.length > maxUrlLength || url.codeUnits.any((c) => c <= 0x20 || c == 0x7f)) return false;
    final uri = Uri.tryParse(url);
    return uri != null && uri.scheme.toLowerCase() == 'https' && uri.host.isNotEmpty;
  }

  /// The header as it is kept with the profile: the same text, in one canonical form.
  String encode() =>
      'v=$version;cur=${current.key};alt=${alternative.key};'
      'alt-url=${base64Url.encode(utf8.encode(alternativeUrl)).replaceAll('=', '')}';

  /// Never shows the link.
  @override
  String toString() => 'ProfileExits(cur=${current.key}, alt=${alternative.key})';

  @override
  bool operator ==(Object other) =>
      other is ProfileExits &&
      other.current == current &&
      other.alternative == alternative &&
      other.alternativeUrl == alternativeUrl;

  @override
  int get hashCode => Object.hash(current, alternative, alternativeUrl);
}

/// What the header said: a pair, or why it gave none.
@immutable
class ExitsVerdict {
  const ExitsVerdict._(this.exits) : reason = null;
  const ExitsVerdict.absent() : exits = null, reason = ExitsDrop.absent;
  const ExitsVerdict.unknownVersion() : exits = null, reason = ExitsDrop.unknownVersion;
  const ExitsVerdict.invalid() : exits = null, reason = ExitsDrop.invalid;

  final ProfileExits? exits;
  final ExitsDrop? reason;

  /// A header that was there and was dropped: worth a line in the app's log.
  bool get dropped => reason == ExitsDrop.unknownVersion || reason == ExitsDrop.invalid;
}

enum ExitsDrop { absent, unknownVersion, invalid }

/// The way out of a subscription of the pair.
enum ExitRole {
  main('main'),
  warp('warp');

  const ExitRole(this.key);

  /// The name in the header, in the settings sent to the core and in the journal.
  final String key;

  ExitRole get other => this == main ? warp : main;

  static ExitRole? tryParse(String? text) {
    final value = text?.trim().toLowerCase();
    for (final role in values) {
      if (role.key == value) return role;
    }
    return null;
  }
}

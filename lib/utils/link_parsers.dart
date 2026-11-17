import 'dart:convert';

import 'package:hiddify/utils/validators.dart';

typedef ProfileLink = ({String url, String name});

// TODO: test and improve
abstract class LinkParser {
  static String generateSubShareLink(String url, [String? name]) {
    final uri = Uri.tryParse(url);
    if (uri == null) return '';
    // replace keeps port and userinfo, which the Uri constructor drops
    return uri.replace(fragment: name).toString();
  }

  /// The app's own link scheme: `sandpiper://import/<url>` or `sandpiper://import?url=<url>`, with
  /// the name in `name=` or the fragment. The schemes of other clients (v2ray, clash, sing-box ...)
  /// are not registered: an app can find which apps handle a scheme without any permission.
  static const scheme = 'sandpiper';
  static const protocols = [scheme];

  static ProfileLink? parse(String link) {
    return simple(link) ?? deep(link);
  }

  static ProfileLink? simple(String link) {
    if (!isUrl(link)) return null;
    final uri = Uri.parse(link.trim());
    return (url: uri.toString(), name: uri.queryParameters['name'] ?? '');
  }

  static ProfileLink? deep(String link) {
    final uri = Uri.tryParse(link.trim());
    if (uri == null || !uri.hasScheme || !uri.hasAuthority) return null;
    if (uri.scheme != scheme || uri.host != 'import') return null;
    final queryParams = uri.queryParameters;
    if (queryParams.containsKey('url')) {
      final name = (queryParams['name']?.isNotEmpty ?? false) ? queryParams['name']! : uri.fragment;
      return (url: queryParams['url']!, name: name);
    }
    if (uri.path.length <= 1) return null;
    return (url: uri.path.substring(1) + (uri.hasQuery ? "?${uri.query}" : ""), name: uri.fragment);
  }
}

String safeDecodeBase64(String str) {
  try {
    return utf8.decode(base64Decode(str));
  } catch (e) {
    return str;
  }
}

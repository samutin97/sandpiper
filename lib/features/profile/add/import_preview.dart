import 'dart:convert';
import 'dart:io';

import 'package:hiddify/features/profile/data/profile_parser.dart';
import 'package:hiddify/singbox/model/singbox_proxy_type.dart';
import 'package:hiddify/utils/link_parsers.dart';

/// Where a profile to import came from (H-04).
enum ImportSource {
  /// A link another app or a web page opened (sandpiper://import/...).
  deepLink,
  clipboard,
  file,
  qrCode,

  /// Typed or pasted on another device and sent here (Android TV).
  phone,
}

/// Why an import is refused before anything is downloaded.
enum ImportRefusal {
  /// A subscription over plain http: the provider would read its URL, token included.
  insecureHttp,
}

/// What the user is shown before a profile is imported: what it is and where it comes from (H-04).
class ImportPreview {
  const ImportPreview({
    required this.name,
    required this.remote,
    this.url,
    this.host,
    this.servers = const [],
    this.serverCount = 0,
    this.refusal,
    this.type,
  });

  /// The kind of a config given in full when it is told apart: "AmneziaWG", "WireGuard".
  final String? type;

  /// The profile's name as far as it can be told before downloading it; may be empty.
  final String name;

  /// A subscription that is downloaded, not a config given in full.
  final bool remote;

  /// The subscription's URL, for a remote profile.
  final String? url;

  /// The subscription's host (with its port when not the default), for a remote profile.
  final String? host;

  /// Up to [maxServers] server addresses (host:port) of a config given in full.
  final List<String> servers;

  /// How many server addresses the config holds in all.
  final int serverCount;

  final ImportRefusal? refusal;

  static const maxServers = 3;
}

final _linkLine = RegExp(r'^([a-z][a-z0-9+.\-]*)://', caseSensitive: false);

/// Tells what importing [rawInput] would add, without any network request.
ImportPreview previewImport(String rawInput) {
  final input = rawInput.trim();
  if (LinkParser.parse(input) case final link?) {
    final uri = Uri.tryParse(link.url.trim());
    final scheme = uri?.scheme.toLowerCase() ?? '';
    final host = uri == null || uri.host.isEmpty ? null : (uri.hasPort ? '${uri.host}:${uri.port}' : uri.host);
    var name = link.name;
    if (name.isEmpty && (uri?.hasFragment ?? false)) name = Uri.decodeComponent(uri!.fragment);
    return ImportPreview(
      name: name,
      remote: true,
      url: link.url,
      host: host,
      refusal: scheme == 'https' ? null : ImportRefusal.insecureHttp,
    );
  }
  // D-07: an AmneziaVPN key holds the private key; only its name and endpoint are shown
  if (input.startsWith('vpn://')) {
    final amnezia = decodeAmneziaKey(input);
    final servers = amnezia == null ? const <String>[] : serverAddresses(amnezia.config);
    return ImportPreview(
      name: amnezia?.name ?? '',
      remote: false,
      type: 'AmneziaWG',
      servers: servers.take(ImportPreview.maxServers).toList(),
      serverCount: servers.length,
    );
  }
  final content = safeDecodeBase64(input);
  final servers = serverAddresses(content);
  final String? type;
  if (content.contains('[Interface]')) {
    type = ProfileParser.protocol(content) == ProxyType.awg.label ? 'AmneziaWG' : 'WireGuard';
  } else {
    type = null;
  }
  return ImportPreview(
    // a .conf has no name of its own: its type is shown instead
    name: type == null ? ProfileParser.protocol(content) : '',
    remote: false,
    type: type,
    servers: servers.take(ImportPreview.maxServers).toList(),
    serverCount: servers.length,
  );
}

/// An AmneziaVPN key (`vpn://`): base64url of a 4-byte big-endian length and the zlib-compressed JSON,
/// whose `containers[].awg.last_config` holds a JSON with the WireGuard/AmneziaWG `.conf` text in
/// `config`; the name is `description`. Null when it does not read so. Only for the import dialog:
/// the core reads the key itself.
({String name, String config})? decodeAmneziaKey(String key) {
  try {
    var payload = key.trim().substring('vpn://'.length).replaceAll(RegExp(r'\s'), '');
    payload = payload.padRight((payload.length + 3) ~/ 4 * 4, '=');
    final bytes = base64Url.decode(payload);
    if (bytes.length < 5) return null;
    final inflated = ZLibDecoder().convert(bytes.sublist(4));
    if (inflated.length > 1 << 20) return null;
    final json = jsonDecode(utf8.decode(inflated));
    if (json is! Map) return null;
    final name = json['description']?.toString() ?? '';
    for (final container in (json['containers'] as List?) ?? const []) {
      if (container is! Map) continue;
      final awg = container['awg'];
      if (awg is! Map) continue;
      final lastConfig = awg['last_config'];
      final inner = lastConfig is String ? jsonDecode(lastConfig) : lastConfig;
      if (inner is Map && inner['config'] is String) return (name: name, config: inner['config'] as String);
    }
    return (name: name, config: '');
  } catch (_) {
    return null;
  }
}

/// A host as a server address can have one: a name or an IPv4/IPv6 address, not a blob of base64
/// that a link without "@" leaves where the host would be.
final _plausibleHost = RegExp(r'^(\[[0-9a-fA-F:.]+\]|[A-Za-z0-9.:\-]{1,253})$');

/// The server addresses (host:port) a config names: proxy links (scheme://...@host:port),
/// WireGuard/AmneziaWG `Endpoint =` lines, and the `server`/`server_port` of a sing-box JSON.
List<String> serverAddresses(String content) {
  final found = <String>[];
  void add(String? address) {
    if (address == null || address.isEmpty || found.contains(address)) return;
    found.add(address);
  }

  final trimmed = content.trimLeft();
  if (trimmed.startsWith('{')) {
    try {
      final json = jsonDecode(trimmed);
      if (json is Map) {
        for (final key in ['outbounds', 'endpoints']) {
          for (final item in (json[key] as List?) ?? const []) {
            if (item is Map && item['server'] is String) {
              add(item['server_port'] == null ? item['server'] as String : '${item['server']}:${item['server_port']}');
            }
            if (item is Map && item['peers'] is List) {
              for (final peer in item['peers'] as List) {
                if (peer is Map && peer['address'] is String) {
                  add(peer['port'] == null ? peer['address'] as String : '${peer['address']}:${peer['port']}');
                }
              }
            }
          }
        }
      }
    } catch (_) {}
    return found;
  }

  for (final rawLine in const LineSplitter().convert(content)) {
    final line = rawLine.trim();
    final endpoint = RegExp(r'^endpoint\s*=\s*(\S+)', caseSensitive: false).firstMatch(line);
    if (endpoint != null) {
      add(endpoint.group(1));
      continue;
    }
    final match = _linkLine.firstMatch(line);
    if (match == null) continue;
    final scheme = match.group(1)!.toLowerCase();
    if (scheme == 'vmess') {
      add(_vmessAddress(line.substring(match.end)));
      continue;
    }
    final uri = Uri.tryParse(line);
    if (uri == null || uri.host.isEmpty) continue;
    // D-07: a link whose "host" is its whole payload (vpn://, ss:// without @) shows nothing
    if (!_plausibleHost.hasMatch(uri.host) || !uri.host.contains('.') && !uri.host.contains(':')) continue;
    add(uri.hasPort ? '${uri.host}:${uri.port}' : uri.host);
  }
  return found;
}

String? _vmessAddress(String payload) {
  try {
    final json = jsonDecode(safeDecodeBase64(payload.split('#').first));
    if (json is Map && json['add'] != null) {
      return json['port'] == null ? '${json['add']}' : '${json['add']}:${json['port']}';
    }
  } catch (_) {}
  return null;
}

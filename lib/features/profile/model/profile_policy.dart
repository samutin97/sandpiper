import 'dart:convert';

import 'package:meta/meta.dart';

/// The subscription server's ranking of its proxies, from the `profile-policy` header of the
/// subscription's HTTP answer (never from the subscription's text). The core reads it again, as
/// strictly (hiddify-core `v2/tiered`); the rules here and there are the same.
///
/// Header value (ASCII, at most [maxLength] characters), items separated by `;`, `v=1` first:
///
///     profile-policy: v=1; n=2:545:main; n=9:335:udp; t=auto:2,3; t=fallback:9; t=last-resort,confirm:10; up=900
///
/// - `n=<ref>:<RSB>[:<caption>[+<caption>]]`: the scores of a proxy, three digits 1..5 — reliability,
///   stealth, security — and at most two caption keys of a fixed set the app translates.
/// - `t=<mode>[,<flag>...]:<ref>,...`: a tier, from the top down. Modes `auto`, `fallback`,
///   `last-resort`, `manual`; flags `confirm` and `max=<minutes>` (last resort only).
/// - parameters `fail`, `retry`, `up`, `hold`, `chk`, `ttl` (numbers, brought to their bounds).
/// - a reference is the number a proxy's name starts with (`2` names "2 …", not "21 …"), or `@` and its
///   exact name, percent-encoded.
///
/// Anything off makes the whole header garbage (nothing kept, the subscription works as without it);
/// unknown keys and flags are skipped. `v=1` alone is a valid empty policy: it clears a kept one.
@immutable
class ProfilePolicy {
  const ProfilePolicy({required this.nodes, required this.tiers, required this.params});

  static const headerName = 'profile-policy';

  /// When the app got the policy (seconds since the epoch), kept beside it in the profile's headers;
  /// never taken from a server.
  static const receivedAtKey = 'profile-policy-at';
  static const maxLength = 2048;
  static const maxNodes = 64;
  static const maxTiers = 8;
  static const maxRefsPerTier = 32;

  /// The caption keys this version shows; any other is not shown.
  static const captionKeys = [
    'main',
    'compact',
    'alt-tls',
    'borrowed-sni',
    'udp',
    'ip-risk',
    'low-volume',
    'slow',
    'mobile',
    'wired',
  ];

  /// The parameters and their bounds (min, max, default); `ttl` in hours, the others in seconds but
  /// `fail`, a count.
  static const bounds = {
    'fail': (1, 4, 2),
    'retry': (2, 30, 4),
    'up': (300, 7200, 900),
    'hold': (60, 3600, 300),
    'chk': (120, 3600, 600),
    'ttl': (24, 720, 168),
  };

  final List<PolicyNode> nodes;
  final List<PolicyTier> tiers;

  /// The parameters the header gave, brought to their bounds.
  final Map<String, int> params;

  bool get isEmpty => tiers.isEmpty;

  /// How long the app keeps the policy when an update of the subscription comes without it.
  Duration get ttl => Duration(hours: params['ttl'] ?? bounds['ttl']!.$3);

  static final _number = RegExp(r'^[1-9][0-9]{0,6}$');
  static final _caption = RegExp(r'^[a-z0-9-]{1,16}$');
  static final _name = RegExp(r'^(?:[A-Za-z0-9\-._~]|%[0-9A-Fa-f]{2})+$');

  /// The policy of a header value, or null for anything that is not one.
  static ProfilePolicy? parse(Object? value) {
    if (value is List) return value.length == 1 ? parse(value.first) : null;
    if (value is! String || value.isEmpty || value.length > maxLength) return null;
    if (value.codeUnits.any((c) => c < 0x20 || c > 0x7e)) return null;
    final nodes = <PolicyNode>[];
    final tiers = <PolicyTier>[];
    final params = <String, int>{};
    final scored = <PolicyRef>{};
    final tiered = <PolicyRef>{};
    var first = true;
    for (final raw in value.split(';')) {
      final item = raw.trim();
      if (item.isEmpty) continue;
      final index = item.indexOf('=');
      if (index <= 0) return null;
      final key = item.substring(0, index).trim();
      final text = item.substring(index + 1).trim();
      if (key.isEmpty) return null;
      if (first) {
        if (key != 'v' || text != '1') return null;
        first = false;
        continue;
      }
      switch (key) {
        case 'v':
          return null;
        case 'n':
          final node = _node(text);
          if (node == null || !scored.add(node.ref)) return null;
          nodes.add(node);
          if (nodes.length > maxNodes) return null;
        case 't':
          final tier = _tier(text);
          if (tier == null) return null;
          for (final ref in tier.refs) {
            if (!tiered.add(ref)) return null;
          }
          tiers.add(tier);
          if (tiers.length > maxTiers) return null;
        default:
          final bound = bounds[key];
          if (bound == null) continue; // a key of a later version
          if (params.containsKey(key)) return null;
          final n = _parseNumber(text);
          if (n == null) return null;
          params[key] = n.clamp(bound.$1, bound.$2);
      }
    }
    if (first) return null;
    return ProfilePolicy(nodes: nodes, tiers: tiers, params: params);
  }

  static int? _parseNumber(String text) => _number.hasMatch(text) ? int.parse(text) : null;

  static PolicyNode? _node(String text) {
    final parts = text.split(':');
    if (parts.length < 2 || parts.length > 3) return null;
    final ref = PolicyRef.parse(parts[0].trim());
    final digits = parts[1].trim();
    if (ref == null || !RegExp(r'^[1-5]{3}$').hasMatch(digits)) return null;
    final captions = <String>[];
    if (parts.length == 3) {
      final items = parts[2].trim().split('+');
      if (items.length > 2) return null;
      for (final c in items) {
        final caption = c.trim();
        if (!_caption.hasMatch(caption)) return null;
        captions.add(caption);
      }
    }
    return PolicyNode(
      ref: ref,
      scores: PolicyScores(
        reliability: int.parse(digits[0]),
        stealth: int.parse(digits[1]),
        security: int.parse(digits[2]),
      ),
      captions: captions,
    );
  }

  static PolicyTier? _tier(String text) {
    final colon = text.indexOf(':');
    if (colon < 0) return null;
    final flags = text.substring(0, colon).split(',');
    final mode = TierMode.fromKey(flags.first.trim());
    if (mode == null) return null;
    var confirm = false;
    int? maxMinutes;
    for (final f in flags.skip(1)) {
      final flag = f.trim();
      if (flag.isEmpty) return null;
      if (flag == 'confirm') {
        confirm = mode == TierMode.lastResort;
      } else if (flag.startsWith('max=')) {
        final n = _parseNumber(flag.substring(4));
        if (n == null) return null;
        if (mode == TierMode.lastResort) maxMinutes = n.clamp(5, 240);
      }
    }
    final refs = <PolicyRef>[];
    for (final item in text.substring(colon + 1).split(',')) {
      final ref = PolicyRef.parse(item.trim());
      if (ref == null || refs.contains(ref)) return null;
      refs.add(ref);
    }
    if (refs.length > maxRefsPerTier) return null;
    return PolicyTier(mode: mode, refs: refs, confirm: confirm, maxMinutes: maxMinutes);
  }

  /// The canonical header value, what the profile keeps (as the core writes it).
  String encode() => [
    'v=1',
    for (final n in nodes) _encodeNode(n),
    for (final t in tiers) _encodeTier(t),
    for (final key in bounds.keys)
      if (params[key] case final v?) '$key=$v',
  ].join(';');

  static String _encodeNode(PolicyNode n) {
    final s = n.scores;
    final captions = n.captions.isEmpty ? '' : ':${n.captions.join('+')}';
    return 'n=${n.ref.encode()}:${s.reliability}${s.stealth}${s.security}$captions';
  }

  static String _encodeTier(PolicyTier t) {
    final flags = '${t.confirm ? ',confirm' : ''}${t.maxMinutes != null ? ',max=${t.maxMinutes}' : ''}';
    return 't=${t.mode.key}$flags:${t.refs.map((r) => r.encode()).join(',')}';
  }

  /// The display name of a tag: without the core's "§…" suffix, trimmed.
  static String displayName(String tag) {
    final i = tag.indexOf('§');
    return (i < 0 ? tag : tag.substring(0, i)).trim();
  }

  /// What the policy says of each proxy of [tags] (the profile's proxies), in the policy's order of
  /// tiers; proxies it does not name are left out (they are manual, without scores).
  Map<String, PolicyPlace> bind(Iterable<String> tags) {
    final list = tags.toList();
    final scores = <String, PolicyNode>{};
    for (final n in nodes) {
      if (n.ref.resolve(list) case final tag?) scores[tag] = n;
    }
    final places = <String, PolicyPlace>{};
    for (var i = 0; i < tiers.length; i++) {
      for (final (order, ref) in tiers[i].refs.indexed) {
        final tag = ref.resolve(list);
        if (tag == null || places.containsKey(tag)) continue;
        places[tag] = PolicyPlace(tier: i, mode: tiers[i].mode, node: scores[tag], order: order);
      }
    }
    // scored proxies outside every tier: manual, with their scores
    for (final MapEntry(key: tag, value: node) in scores.entries) {
      places.putIfAbsent(tag, () => PolicyPlace(tier: tiers.length, mode: TierMode.manual, node: node));
    }
    return places;
  }

  @override
  bool operator ==(Object other) => other is ProfilePolicy && other.encode() == encode();

  @override
  int get hashCode => encode().hashCode;

  @override
  String toString() => 'ProfilePolicy(${encode()})';
}

enum TierMode {
  auto('auto'),
  fallback('fallback'),
  lastResort('last-resort'),
  manual('manual');

  const TierMode(this.key);
  final String key;

  static TierMode? fromKey(String key) => values.where((m) => m.key == key).firstOrNull;

  /// A reserve: used only once the proxies above fail.
  bool get isReserve => this == fallback || this == lastResort;
}

@immutable
class PolicyScores {
  const PolicyScores({required this.reliability, required this.stealth, required this.security});
  final int reliability;
  final int stealth;
  final int security;

  @override
  bool operator ==(Object other) =>
      other is PolicyScores &&
      other.reliability == reliability &&
      other.stealth == stealth &&
      other.security == security;

  @override
  int get hashCode => Object.hash(reliability, stealth, security);
}

@immutable
class PolicyRef {
  const PolicyRef.number(int this.number) : name = null;
  const PolicyRef.name(String this.name) : number = null;

  final int? number;
  final String? name;

  static final _digits = RegExp(r'^[1-9][0-9]{0,2}$');

  static PolicyRef? parse(String text) {
    if (text.startsWith('@')) {
      final escaped = text.substring(1);
      if (!ProfilePolicy._name.hasMatch(escaped)) return null;
      // the escapes are checked above: decoded by hand, malformed UTF-8 becomes U+FFFD, refused
      final bytes = <int>[];
      for (var i = 0; i < escaped.length; i++) {
        if (escaped[i] == '%') {
          bytes.add(int.parse(escaped.substring(i + 1, i + 3), radix: 16));
          i += 2;
        } else {
          bytes.add(escaped.codeUnitAt(i));
        }
      }
      if (bytes.length > 96) return null;
      final name = utf8.decode(bytes, allowMalformed: true);
      if (name.isEmpty || name.codeUnits.any((c) => c < 0x20 || c == 0x7f || c == 0xFFFD)) return null;
      return PolicyRef.name(name);
    }
    if (!_digits.hasMatch(text)) return null;
    return PolicyRef.number(int.parse(text));
  }

  String encode() {
    if (number != null) return '$number';
    final b = StringBuffer('@');
    for (final byte in Uri.encodeComponent(name!).codeUnits) {
      b.writeCharCode(byte);
    }
    // encodeComponent leaves !'()* as they are; the format allows only unreserved characters
    return b.toString().replaceAllMapped(
      RegExp("[!'()*]"),
      (m) => '%${m[0]!.codeUnitAt(0).toRadixString(16).toUpperCase()}',
    );
  }

  /// The number a display name starts with (followed by its end or a non-digit), or null.
  static int? numberOf(String name) {
    final m = RegExp('^([1-9][0-9]{0,2})(?![0-9])').firstMatch(name);
    return m == null ? null : int.parse(m[1]!);
  }

  /// The one tag of [tags] this reference names; null for none or several.
  String? resolve(List<String> tags) {
    String? found;
    for (final tag in tags) {
      final display = ProfilePolicy.displayName(tag);
      final match = number != null ? numberOf(display) == number : display == name;
      if (!match) continue;
      if (found != null) return null;
      found = tag;
    }
    return found;
  }

  @override
  bool operator ==(Object other) => other is PolicyRef && other.number == number && other.name == name;

  @override
  int get hashCode => Object.hash(number, name);
}

@immutable
class PolicyNode {
  const PolicyNode({required this.ref, required this.scores, this.captions = const []});
  final PolicyRef ref;
  final PolicyScores scores;

  /// Keys of [ProfilePolicy.captionKeys]; unknown ones are kept but not shown.
  final List<String> captions;

  /// The captions this version can show.
  List<String> get shownCaptions => captions.where(ProfilePolicy.captionKeys.contains).toList();
}

@immutable
class PolicyTier {
  const PolicyTier({required this.mode, required this.refs, this.confirm = false, this.maxMinutes});
  final TierMode mode;
  final List<PolicyRef> refs;
  final bool confirm;
  final int? maxMinutes;
}

/// Where the policy puts one proxy: its tier and mode, and its scores when the policy gives them.
@immutable
class PolicyPlace {
  const PolicyPlace({required this.tier, required this.mode, this.node, this.order = 0});
  final int tier;
  final TierMode mode;
  final PolicyNode? node;

  /// Its place in its tier as the policy lists it.
  final int order;

  /// The order the core tries proxies in (hiddify-core `Bind`): by tier, then the scored ones, the
  /// higher sum first, then as the policy lists them.
  static int compare(PolicyPlace a, PolicyPlace b) {
    if (a.tier != b.tier) return a.tier.compareTo(b.tier);
    if ((a.node == null) != (b.node == null)) return a.node == null ? 1 : -1;
    int sum(PolicyScores? s) => s == null ? 0 : s.reliability + s.stealth + s.security;
    final sumA = sum(a.node?.scores);
    final sumB = sum(b.node?.scores);
    if (sumA != sumB) return sumB.compareTo(sumA);
    return a.order.compareTo(b.order);
  }
}

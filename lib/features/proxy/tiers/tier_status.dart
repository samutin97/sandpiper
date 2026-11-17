import 'dart:convert';

import 'package:hiddify/features/profile/model/profile_policy.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:meta/meta.dart';

/// The core's group that chooses by the server's rating (hiddify-core `v2/config/tier_group.go`).
const tieredGroupTag = 'tiered';

/// The core's state of the choice by the server's rating, from `OutboundGroup.tier_state` of the
/// tiered group (hiddify-core `v2/tiered` State).
@immutable
class TierStatus {
  const TierStatus({
    required this.tier,
    required this.mode,
    required this.node,
    required this.reason,
    this.checking = false,
    this.confirm = '',
    this.down = const [],
  });

  /// Index of the active proxy's tier in the policy; -1 when none is in use.
  final int tier;
  final TierMode? mode;

  /// The proxy in use (a tag), empty when none.
  final String node;

  /// `ok`, `checking`, `node-failed`, `tcp-blocked`, `slow`, `offline`, `none`, `confirm`, `idle`.
  final String reason;
  final bool checking;

  /// The last-resort proxy that waits for the user's agreement, empty when none.
  final String confirm;

  /// Proxies that failed in this network.
  final List<String> down;

  static const reasonNodeFailed = 'node-failed';
  static const reasonTcp = 'tcp-blocked';
  static const reasonSlow = 'slow';
  static const reasonNone = 'none';
  static const reasonConfirm = 'confirm';
  static const reasonOffline = 'offline';
  static const reasonChecking = 'checking';
  static const reasonIdle = 'idle';

  /// The state of a tier_state value; null for an empty or unreadable one.
  static TierStatus? parse(String json) {
    if (json.isEmpty) return null;
    try {
      final m = jsonDecode(json);
      if (m is! Map<String, dynamic>) return null;
      return TierStatus(
        tier: m['tier'] is int ? m['tier'] as int : -1,
        mode: TierMode.fromKey('${m['mode'] ?? ''}'),
        node: m['node'] is String ? m['node'] as String : '',
        reason: m['reason'] is String ? m['reason'] as String : '',
        checking: m['checking'] == true,
        confirm: m['confirm'] is String ? m['confirm'] as String : '',
        down: [
          for (final d in (m['down'] is List ? m['down'] as List : const []))
            if (d is String) d,
        ],
      );
    } on FormatException {
      return null;
    }
  }

  /// A reserve proxy is in use: the main options fail in this network.
  bool get onReserve => node.isNotEmpty && (mode?.isReserve ?? false) && reason != reasonChecking;

  bool get onLastResort => onReserve && mode == TierMode.lastResort;

  bool get waitsForUser => reason == reasonConfirm && confirm.isNotEmpty;
}

/// The tiered group's state while the user has it picked in the main group; null otherwise (no
/// policy, another pick, the core not running).
TierStatus? tierStatusOf(OutboundGroupList? list) {
  if (list == null || list.items.isEmpty) return null;
  final main = list.items.first;
  final picked = main.items.firstOrNull;
  if (picked == null || picked.tag != tieredGroupTag) return null;
  final group = list.items.where((g) => g.tag == tieredGroupTag).firstOrNull;
  if (group == null) return null;
  return TierStatus.parse(group.tierState);
}

final tierStatusProvider = Provider<TierStatus?>(
  (ref) => tierStatusOf(ref.watch(mainOutboundsNotifierProvider).valueOrNull),
);

/// The active profile's ranking by its server; null without one.
final activePolicyProvider = Provider<ProfilePolicy?>(
  (ref) => ref.watch(activeProfileProvider.select((profile) => profile.valueOrNull?.policy)),
);

/// The sections of the proxies page with a policy: the groups first, then the proxies of each mode in
/// the server's order (the order the core tries them), and the proxies the policy does not name last,
/// in the user's sort.
List<({TierMode? mode, List<OutboundInfo> items})> tierSections(List<OutboundInfo> items, Map<String, PolicyPlace> places) {
  final groups = items.where((e) => e.isGroup).toList();
  final byMode = <TierMode, List<OutboundInfo>>{for (final m in TierMode.values) m: []};
  for (final item in items.where((e) => !e.isGroup)) {
    byMode[places[item.tag]?.mode ?? TierMode.manual]!.add(item);
  }
  for (final mode in [TierMode.auto, TierMode.fallback, TierMode.lastResort]) {
    byMode[mode]!.sort((a, b) => PolicyPlace.compare(places[a.tag]!, places[b.tag]!));
  }
  return [
    if (groups.isNotEmpty) (mode: null, items: groups),
    for (final mode in TierMode.values)
      if (byMode[mode]!.isNotEmpty) (mode: mode, items: byMode[mode]!),
  ];
}

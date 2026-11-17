import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/notification/in_app_notification_controller.dart';
import 'package:hiddify/features/profile/model/profile_policy.dart';
import 'package:hiddify/features/proxy/data/proxy_data_providers.dart';
import 'package:hiddify/features/proxy/model/proxy_entity.dart';
import 'package:hiddify/features/proxy/tiers/tier_status.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

// What the server's rating shows: the three scores of a proxy, the reserve marks, the sections of the
// proxies page, the switch, and the home screen's note when a reserve is in use. Nothing of it shows
// without a policy from the server: the app makes up no scores of its own.

/// The text of a caption key, null for a key this version does not know.
String? tierCaption(Translations t, String key) {
  final c = t.fork.tiers.captions;
  return switch (key) {
    'main' => c.main,
    'compact' => c.compact,
    'alt-tls' => c.altTls,
    'borrowed-sni' => c.borrowedSni,
    'udp' => c.udp,
    'ip-risk' => c.ipRisk,
    'low-volume' => c.lowVolume,
    'slow' => c.slow,
    'mobile' => c.mobile,
    'wired' => c.wired,
    _ => null,
  };
}

/// The title of a section of the proxies page.
String tierSectionTitle(Translations t, TierMode mode) => switch (mode) {
  TierMode.auto => t.fork.tiers.recommended,
  TierMode.fallback => t.fork.tiers.reserve,
  TierMode.lastResort => t.fork.tiers.lastResort,
  TierMode.manual => t.fork.tiers.other,
};

/// The three scores in full, as a sentence for a tooltip or a screen reader.
String tierScoresText(Translations t, PolicyScores s) =>
    '${t.fork.tiers.reliability} ${s.reliability} · ${t.fork.tiers.stealth} ${s.stealth} · '
    '${t.fork.tiers.security} ${s.security}';

({Color background, Color foreground}) _reserveColors(BuildContext context, TierMode mode) {
  final s = Theme.of(context).colorScheme;
  return mode == TierMode.lastResort
      ? (background: s.tertiaryContainer, foreground: s.onTertiaryContainer)
      : (background: s.secondaryContainer, foreground: s.onSecondaryContainer);
}

/// The signs of the three scores, in a row and beside their names in a proxy's details.
const tierReliabilityIcon = Icons.verified_outlined;
const tierStealthIcon = Icons.visibility_off_outlined;
const tierSecurityIcon = Icons.lock_outline_rounded;

/// "reserve" or "last resort", as a small chip, or its sign alone where room is short; nothing for
/// the other modes.
class TierBadge extends ConsumerWidget {
  const TierBadge(this.mode, {super.key, this.iconOnly = false});
  final TierMode mode;
  final bool iconOnly;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!mode.isReserve) return const SizedBox.shrink();
    final t = ref.watch(translationsProvider).requireValue;
    final colors = _reserveColors(context, mode);
    final label = mode == TierMode.lastResort ? t.fork.tiers.lastResortBadge : t.fork.tiers.reserveBadge;
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: iconOnly ? 3 : 6, vertical: 1),
        decoration: BoxDecoration(color: colors.background, borderRadius: BorderRadius.circular(6)),
        child: iconOnly
            ? Icon(
                mode == TierMode.lastResort ? Icons.warning_amber_rounded : Icons.alt_route_rounded,
                size: 13,
                color: colors.foreground,
              )
            : Text(
                label,
                maxLines: 1,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(color: colors.foreground, height: 1.2),
              ),
      ),
    );
  }
}

/// A proxy's place in the server's rating, on one line of a proxies-page row: the reserve chip, then
/// the three scores as signs and numbers (their names are in the details and for screen readers).
/// It always fits: where the row is narrow the chip is a sign alone, and the line shrinks rather
/// than being cut.
class TierRatingsLine extends ConsumerWidget {
  const TierRatingsLine(this.place, {super.key});
  final PolicyPlace place;

  /// Under this width the reserve chip is its sign alone.
  static const chipWidth = 190.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final scores = place.node?.scores;
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    final style = Theme.of(context).textTheme.labelMedium?.copyWith(color: color, height: 1.1, fontWeight: FontWeight.w600);
    final reserve = place.mode.isReserve;
    final words = [
      if (reserve) place.mode == TierMode.lastResort ? t.fork.tiers.lastResortBadge : t.fork.tiers.reserveBadge,
      if (scores != null) tierScoresText(t, scores),
    ].join(' · ');
    Widget score(IconData icon, int value) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const Gap(2),
        Text('$value', style: style),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) => Semantics(
        label: words,
        excludeSemantics: true,
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (reserve) ...[
                  TierBadge(place.mode, iconOnly: constraints.maxWidth < chipWidth),
                  const Gap(8),
                ],
                if (scores != null) ...[
                  score(tierReliabilityIcon, scores.reliability),
                  const Gap(10),
                  score(tierStealthIcon, scores.stealth),
                  const Gap(10),
                  score(tierSecurityIcon, scores.security),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A section title of the proxies page with a policy.
class TierSectionHeader extends ConsumerWidget {
  const TierSectionHeader(this.mode, {super.key});
  final TierMode mode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);
    final color = switch (mode) {
      TierMode.auto => theme.colorScheme.primary,
      TierMode.lastResort => theme.colorScheme.tertiary,
      _ => theme.colorScheme.secondary,
    };
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(16, 16, 16, 4),
      child: Row(
        children: [
          Icon(switch (mode) {
            TierMode.auto => Icons.verified_outlined,
            TierMode.fallback => Icons.alt_route_rounded,
            TierMode.lastResort => Icons.warning_amber_rounded,
            TierMode.manual => Icons.tune_rounded,
          }, size: 18, color: color),
          const Gap(8),
          Expanded(
            child: Text(
              tierSectionTitle(t, mode),
              style: theme.textTheme.titleSmall?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// The scores of a proxy in its details: one bar each, its place in the rating, the server's captions
/// and what the scale means. Nothing for a proxy the policy gives no place.
class TierDetails extends ConsumerWidget {
  const TierDetails(this.place, {super.key});
  final PolicyPlace place;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);
    final tr = t.fork.tiers;
    final scores = place.node?.scores;
    final captions = [for (final key in place.node?.captions ?? const <String>[]) ?tierCaption(t, key)];
    Widget bar(IconData icon, String label, int value) => Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
          const Gap(6),
          SizedBox(width: 104, child: Text(label, style: theme.textTheme.bodyMedium)),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(value: value / 5, minHeight: 8),
            ),
          ),
          const Gap(8),
          Text(tr.outOf(n: value), style: theme.textTheme.labelMedium),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(tr.ratingsTitle, style: theme.textTheme.titleSmall),
              const Gap(8),
              TierBadge(place.mode),
            ],
          ),
          const Gap(2),
          Text(switch (place.mode) {
            TierMode.auto => tr.place.recommended,
            TierMode.fallback => tr.place.reserve,
            TierMode.lastResort => tr.place.lastResort,
            TierMode.manual => tr.place.manual,
          }, style: theme.textTheme.bodySmall),
          if (scores != null) ...[
            bar(tierReliabilityIcon, tr.reliability, scores.reliability),
            bar(tierStealthIcon, tr.stealth, scores.stealth),
            bar(tierSecurityIcon, tr.security, scores.security),
          ],
          for (final caption in captions)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline_rounded, size: 16, color: theme.colorScheme.onSurfaceVariant),
                  const Gap(6),
                  Expanded(child: Text(caption, style: theme.textTheme.bodySmall)),
                ],
              ),
            ),
          if (scores != null) ...[
            const Gap(8),
            Text(
              tr.scaleHint,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}

/// The details of [tag] when the active profile's server rates it: [TierDetails]; else nothing.
class TierDetailsOf extends ConsumerWidget {
  const TierDetailsOf(this.tag, {super.key, this.tags});
  final String tag;

  /// Every proxy of the profile, to tell a reference that names two of them; [tag] alone without.
  final List<String>? tags;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final policy = ref.watch(activePolicyProvider);
    if (policy == null) return const SizedBox.shrink();
    final place = policy.bind(tags ?? [tag])[tag];
    return place == null ? const SizedBox.shrink() : TierDetails(place);
  }
}

/// The switch over the proxies page: on, the tiered group is picked in the main group; off, the
/// fastest (lowest) is. Only with the tiered group in the list.
class TierSwitch extends ConsumerWidget {
  const TierSwitch({super.key, required this.group, required this.onSelect});
  final OutboundGroup group;
  final Future<void> Function(String tag) onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!group.items.any((e) => e.tag == tieredGroupTag)) return const SizedBox.shrink();
    final t = ref.watch(translationsProvider).requireValue;
    final on = group.selected == tieredGroupTag;
    return SwitchListTile(
      value: on,
      title: Text(t.fork.tiers.switchTitle),
      subtitle: Text(t.fork.tiers.switchSubtitle),
      secondary: const Icon(Icons.leaderboard_outlined),
      onChanged: (value) {
        if (value) {
          onSelect(tieredGroupTag);
          return;
        }
        final fallback =
            group.items.where((e) => e.tag == lowestGroupTag).firstOrNull ??
            group.items.where((e) => !e.isGroup).firstOrNull;
        if (fallback != null) onSelect(fallback.tag);
      },
    );
  }
}

/// The home screen's note while the choice by the server's rating has to use a reserve, has nothing
/// working, or waits for the user's agreement to the last resort. Not shown otherwise.
class TierBanner extends HookConsumerWidget {
  const TierBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(tierStatusProvider);
    final t = ref.watch(translationsProvider).requireValue;
    final dismissed = useState<String?>(null);
    final wasLastResort = useRef(false);
    final lastResortNode = status?.onLastResort ?? false ? status!.node : null;
    useEffect(() {
      // a toast when the last resort starts, once
      if (lastResortNode != null && !wasLastResort.value) {
        Future.microtask(
          () => ref
              .read(inAppNotificationControllerProvider)
              .showInfoToast(t.fork.tiers.banner.toast(name: ProfilePolicy.displayName(lastResortNode))),
        );
      }
      wasLastResort.value = lastResortNode != null;
      return null;
    }, [lastResortNode]);
    if (status == null) return const SizedBox.shrink();
    final b = t.fork.tiers.banner;
    if (status.waitsForUser) {
      if (dismissed.value == status.confirm) return const SizedBox.shrink();
      final name = ProfilePolicy.displayName(status.confirm);
      return _BannerCard(
        mode: TierMode.lastResort,
        title: b.confirmTitle,
        lines: [b.confirmBody(name: name)],
        actions: [
          TextButton(onPressed: () => dismissed.value = status.confirm, child: Text(b.notNow)),
          FilledButton.tonal(
            onPressed: () async {
              final ok = await ref
                  .read(proxyRepositoryProvider)
                  .selectProxy(tieredGroupTag, status.confirm)
                  .map((_) => true)
                  .getOrElse((_) => false)
                  .run();
              if (!ok) ref.read(inAppNotificationControllerProvider).showErrorToast(b.confirmFailed);
            },
            child: Text(b.use),
          ),
        ],
      );
    }
    if (status.reason == TierStatus.reasonNone) {
      return _BannerCard(mode: TierMode.fallback, title: null, lines: [b.none]);
    }
    if (!status.onReserve) return const SizedBox.shrink();
    final name = ProfilePolicy.displayName(status.node);
    final why = switch (status.reason) {
      TierStatus.reasonTcp => b.tcpBlocked,
      TierStatus.reasonSlow => b.slow,
      _ => b.nodeFailed,
    };
    return _BannerCard(
      mode: status.mode!,
      title: status.onLastResort ? b.lastResortTitle(name: name) : b.reserveTitle(name: name),
      lines: [why, if (status.onLastResort) b.lastResortHint, b.backUp],
    );
  }
}

class _BannerCard extends StatelessWidget {
  const _BannerCard({required this.mode, required this.title, required this.lines, this.actions = const []});
  final TierMode mode;
  final String? title;
  final List<String> lines;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = _reserveColors(context, mode);
    return Card(
      key: const ValueKey('tier-banner'),
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      color: colors.background,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  mode == TierMode.lastResort ? Icons.warning_amber_rounded : Icons.alt_route_rounded,
                  size: 20,
                  color: colors.foreground,
                ),
                const Gap(10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (title case final title?)
                        Text(title, style: theme.textTheme.titleSmall?.copyWith(color: colors.foreground)),
                      for (final line in lines)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(line, style: theme.textTheme.bodySmall?.copyWith(color: colors.foreground)),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            if (actions.isNotEmpty)
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: Wrap(spacing: 8, children: actions),
              )
            else
              const Gap(4),
          ],
        ),
      ),
    );
  }
}

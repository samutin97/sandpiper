import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/features/profile/model/profile_exits.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/profile/notifier/exit_choice_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// A compact row under the connect button: the way out to the internet, main or Cloudflare WARP.
/// Shown only while the active profile's server offered the pair (`profile-exits`); the choice is
/// the profile's, and taking the other one makes the connection again with it.
class ExitChoiceRow extends ConsumerWidget {
  const ExitChoiceRow({super.key});

  /// Below this height (logical pixels) the hint line is left out.
  static const compactHeight = 700.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(activeProfileProvider).valueOrNull;
    final current = ExitChoice.current(profile);
    if (profile == null || current == null) return const SizedBox.shrink();
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);
    final busy = ref.watch(exitChoiceNotifierProvider).isLoading;
    // on a small or a wide-and-low screen the one-line hint goes: the two ways out stay
    final size = MediaQuery.sizeOf(context);
    final compact = size.height < compactHeight || size.width > size.height;
    return Padding(
      key: const ValueKey('exit_choice_row'),
      padding: EdgeInsets.fromLTRB(16, compact ? 4 : 12, 16, compact ? 4 : 0),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              busy ? t.fork.exits.switching : t.fork.exits.title,
              style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const Gap(6),
            SegmentedButton<ExitRole>(
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: [
                ButtonSegment(value: ExitRole.main, label: Text(t.fork.exits.main)),
                ButtonSegment(value: ExitRole.warp, label: Text(t.fork.exits.warp)),
              ],
              selected: {current},
              onSelectionChanged: busy
                  ? null
                  : (selection) => ref.read(exitChoiceNotifierProvider.notifier).choose(profile, selection.first),
            ),
            if (!compact) ...[
              const Gap(4),
              Text(
                '${t.fork.exits.warp}: ${t.fork.exits.warpHint}',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

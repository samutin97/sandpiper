import 'package:flutter/material.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/optional_range.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/features/settings/widget/dpi_probe_dialog.dart';
import 'package:hiddify/features/settings/widget/preference_tile.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class TlsTricksPage extends HookConsumerWidget {
  const TlsTricksPage({super.key});

  String _presentFragmentPackets(TranslationsEn t, String value) => switch (value) {
    "tlshello" => t.pages.settings.tlsTricks.packetsTlsHello,
    "1-1" => t.pages.settings.tlsTricks.packets1_1,
    "1-2" => t.pages.settings.tlsTricks.packets1_2,
    "1-3" => t.pages.settings.tlsTricks.packets1_3,
    "1-4" => t.pages.settings.tlsTricks.packets1_4,
    "1-5" => t.pages.settings.tlsTricks.packets1_5,
    _ => value,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final canChangeOption = ref.watch(ConfigOptions.enableTlsFragment);
    return Scaffold(
      appBar: AppBar(title: Text(t.pages.settings.tlsTricks.title)),
      body: ListView(
        children: [
          // P21: a ClientHello that fits one TCP segment, for TLS that is not REALITY
          SwitchListTile.adaptive(
            title: Text(t.fork.tls.compact),
            subtitle: Text(t.fork.tls.compactMsg),
            secondary: const Icon(Icons.compress_rounded),
            value: ref.watch(ConfigOptions.tlsKeyShare) == 'classical',
            onChanged: (value) => ref.read(ConfigOptions.tlsKeyShare.notifier).update(value ? 'classical' : ''),
          ),
          // P2: TLS without a certificate check only when the user allows it, warned first
          SwitchListTile.adaptive(
            title: Text(t.fork.tls.insecure),
            subtitle: Text(t.fork.tls.insecureMsg),
            secondary: const Icon(Icons.gpp_maybe_rounded),
            value: ref.watch(ConfigOptions.allowInsecure),
            onChanged: (value) async {
              if (value &&
                  !await ref
                      .read(dialogNotifierProvider.notifier)
                      .showConfirmation(title: t.fork.tls.insecure, message: t.fork.tls.insecureWarning)) {
                return;
              }
              await ref.read(ConfigOptions.allowInsecure.notifier).update(value);
            },
          ),
          ListTile(
            leading: const Icon(Icons.troubleshoot_rounded),
            title: Text(t.fork.dpiProbe.title),
            subtitle: Text(t.fork.dpiProbe.tile),
            onTap: () => showDialog<void>(context: context, builder: (_) => const DpiProbeDialog()),
          ),
          const Divider(),
          SwitchListTile.adaptive(
            title: Text(t.pages.settings.tlsTricks.enable),
            value: ref.watch(ConfigOptions.enableTlsFragment),
            secondary: const Icon(Icons.content_cut_rounded),
            onChanged: ref.read(ConfigOptions.enableTlsFragment.notifier).update,
          ),
          ChoicePreferenceWidget(
            selected: ref.watch(ConfigOptions.fragmentPackets),
            preferences: ref.watch(ConfigOptions.fragmentPackets.notifier),
            choices: const ["tlshello", "1-1", "1-2", "1-3", "1-4", "1-5"],
            title: t.pages.settings.tlsTricks.packets,
            icon: Icons.layers_rounded,
            presentChoice: (value) => _presentFragmentPackets(t, value),
            enabled: canChangeOption,
          ),
          ValuePreferenceWidget(
            value: ref.watch(ConfigOptions.tlsFragmentSize),
            preferences: ref.watch(ConfigOptions.tlsFragmentSize.notifier),
            title: t.pages.settings.tlsTricks.size,
            icon: Icons.straighten_rounded,
            inputToValue: OptionalRange.tryParse,
            presentValue: (value) => value.present(t),
            formatInputValue: (value) => value.format(),
            enabled: canChangeOption,
          ),
          ValuePreferenceWidget(
            value: ref.watch(ConfigOptions.tlsFragmentSleep),
            preferences: ref.watch(ConfigOptions.tlsFragmentSleep.notifier),
            title: t.pages.settings.tlsTricks.sleep,
            icon: Icons.snooze_rounded,
            inputToValue: OptionalRange.tryParse,
            presentValue: (value) => value.present(t),
            formatInputValue: (value) => value.format(),
            enabled: canChangeOption,
          ),
          SwitchListTile.adaptive(
            title: Text(t.pages.settings.tlsTricks.mixedSniCase.enable),
            value: ref.watch(ConfigOptions.enableTlsMixedSniCase),
            secondary: const Icon(Icons.text_fields_rounded),
            onChanged: canChangeOption ? ref.read(ConfigOptions.enableTlsMixedSniCase.notifier).update : null,
          ),
          SwitchListTile.adaptive(
            title: Text(t.pages.settings.tlsTricks.padding.enable),
            value: ref.watch(ConfigOptions.enableTlsPadding),
            secondary: const Icon(Icons.expand_rounded),
            onChanged: canChangeOption ? ref.read(ConfigOptions.enableTlsPadding.notifier).update : null,
          ),
          ValuePreferenceWidget(
            value: ref.watch(ConfigOptions.tlsPaddingSize),
            preferences: ref.watch(ConfigOptions.tlsPaddingSize.notifier),
            title: t.pages.settings.tlsTricks.padding.size,
            icon: Icons.straighten_rounded,
            inputToValue: OptionalRange.tryParse,
            presentValue: (value) => value.format(),
            formatInputValue: (value) => value.format(),
            enabled: canChangeOption,
          ),
        ],
      ),
    );
  }
}

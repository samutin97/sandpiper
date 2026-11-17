import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/region.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/features/app_based_routing/overview/app_based_routing_notifier.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/utils/platform_utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Item 8 (H-08, leak B): once, after the intro, offers to keep the installed Russian apps out of
/// the VPN: banks, marketplaces, Gosuslugi, VK, Yandex, operators ... Inside the tunnel such an app
/// learns the server's exit address with any request abroad, and some look for VPNs on purpose.
Future<void> offerSplitTunnel(WidgetRef ref) async {
  if (!PlatformUtils.isAndroid) return;
  if (!ref.read(Preferences.introCompleted) || ref.read(Preferences.splitTunnelOffered)) return;
  if (ref.read(ConfigOptions.region) != Region.ru) return;
  // already set up by the user
  if (ref.read(Preferences.perAppProxyEnabled)) {
    await ref.read(Preferences.splitTunnelOffered.notifier).update(true);
    return;
  }
  await ref.read(appBasedRoutingProvider.future);
  final routing = ref.read(appBasedRoutingProvider.notifier);
  final installed = await routing.installedFromBuiltinList();
  final t = ref.read(translationsProvider).requireValue;
  final names = installed.toList()..sort();
  final accepted = await ref
      .read(dialogNotifierProvider.notifier)
      .showConfirmation(
        title: t.fork.split.title,
        message: [
          t.fork.split.msg(n: installed.length),
          if (names.isNotEmpty) names.take(12).join(', ') + (names.length > 12 ? ' ...' : ''),
          t.fork.split.after,
        ].join('\n\n'),
        positiveBtnTxt: t.fork.split.confirm,
      );
  await ref.read(Preferences.splitTunnelOffered.notifier).update(true);
  if (accepted) await routing.excludeBuiltinList();
}

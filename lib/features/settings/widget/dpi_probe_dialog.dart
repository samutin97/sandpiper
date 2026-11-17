import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/model/profile_probe.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/hiddifycore/dpi_probe.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service_provider.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// The path diagnostic of the hardened core (core-app-interface.md 8.2), run only from here, by the
/// user's tap: TCP, TLS, then a download (and an upload) to a server. It dials directly, outside the
/// VPN, as the app's own core does; so it tells whether the network cuts the ClientHello or freezes a
/// transfer at 16 KB. By default it checks the host of the active profile's subscription with the
/// test paths that subscription's server gave (`profile-probe`, [ProfileProbe]); without them, the
/// paths typed here last time (kept as settings).
///
/// SP3-01: the progress and the result are shown first, above the form, which folds while a check
/// runs; the button shows the progress too. Nothing the user waits for is below the fold.
class DpiProbeDialog extends HookConsumerWidget {
  const DpiProbeDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final s = t.fork.dpiProbe;
    final host = useTextEditingController();
    final port = useTextEditingController(text: '443');
    final sni = useTextEditingController();
    final path = useTextEditingController(text: ref.read(Preferences.dpiProbeDownloadPath));
    final uploadPath = useTextEditingController(text: ref.read(Preferences.dpiProbeUploadPath));
    final upload = useState(true);
    final classical = useState(false);
    final running = useState(false);
    final elapsed = useState(0);
    final result = useState<String?>(null);
    final formOpen = useState(true);
    final fromProfile = useState<ProfileProbe?>(null);
    final scroll = useScrollController();

    // the host of the active profile's subscription and the test paths its server gave
    useEffect(() {
      ref.read(activeProfileProvider.future).then((profile) {
        if (!context.mounted) return;
        if (profile case RemoteProfileEntity(:final url) when host.text.isEmpty) {
          host.text = Uri.tryParse(url)?.host ?? '';
        }
        if (profile?.probe case final probe?) {
          path.text = probe.getPath;
          uploadPath.text = probe.postPath ?? '';
          upload.value = probe.canUpload;
          fromProfile.value = probe;
        }
      });
      return null;
    }, const []);

    Future<void> run() async {
      if (host.text.trim().isEmpty) return;
      running.value = true;
      result.value = null;
      elapsed.value = 0;
      formOpen.value = false;
      if (scroll.hasClients) {
        unawaited(scroll.animateTo(0, duration: const Duration(milliseconds: 200), curve: Curves.easeOut));
      }
      // what the user typed is kept for the next time; the subscription's own paths are not copied
      final probe = fromProfile.value;
      if (probe == null || path.text.trim() != probe.getPath || uploadPath.text.trim() != (probe.postPath ?? '')) {
        await ref.read(Preferences.dpiProbeDownloadPath.notifier).update(path.text.trim());
        await ref.read(Preferences.dpiProbeUploadPath.notifier).update(uploadPath.text.trim());
      }
      final started = DateTime.now();
      final ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        elapsed.value = DateTime.now().difference(started).inSeconds;
      });
      try {
        final client = ref.read(hiddifyCoreServiceProvider).core.fgClient;
        final r = await runDpiProbe(
          client,
          DpiProbeParams(
            host: host.text.trim(),
            port: int.tryParse(port.text.trim()) ?? 443,
            serverName: sni.text.trim(),
            path: path.text.trim().isEmpty ? '/' : path.text.trim(),
            uploadPath: uploadPath.text.trim(),
            upload: upload.value,
            classicalKeyShare: classical.value,
          ),
        ).timeout(const Duration(seconds: 75));
        final seconds = DateTime.now().difference(started).inMilliseconds / 1000;
        result.value = describeDpiProbe(t, r, seconds);
      } on TimeoutException {
        result.value = s.noAnswer;
      } catch (e) {
        result.value = '${s.failed}: $e';
      } finally {
        ticker.cancel();
        running.value = false;
      }
    }

    final theme = Theme.of(context);
    final pathsNote = fromProfile.value != null
        ? s.fromProfile
        : path.text.trim().isEmpty
        ? s.noPaths
        : null;

    return AlertDialog(
      title: Text(s.title),
      content: SingleChildScrollView(
        controller: scroll,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(s.msg, style: theme.textTheme.bodySmall),
            if (running.value) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
              const SizedBox(height: 4),
              Text(s.running(seconds: elapsed.value)),
            ],
            if (result.value != null) ...[
              const SizedBox(height: 12),
              Text(s.outcome, style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Padding(padding: const EdgeInsets.all(8), child: SelectableText(result.value!)),
              ),
            ],
            const SizedBox(height: 4),
            ListTile(
              key: const ValueKey('dpi-probe-parameters'),
              contentPadding: EdgeInsets.zero,
              title: Text(s.parameters),
              subtitle: pathsNote == null ? null : Text(pathsNote, style: theme.textTheme.bodySmall),
              trailing: Icon(formOpen.value ? Icons.expand_less : Icons.expand_more),
              onTap: () => formOpen.value = !formOpen.value,
            ),
            if (formOpen.value) ...[
              TextField(controller: host, decoration: InputDecoration(labelText: s.host)),
              TextField(
                controller: port,
                decoration: InputDecoration(labelText: s.port),
                keyboardType: TextInputType.number,
              ),
              TextField(controller: sni, decoration: InputDecoration(labelText: s.sni)),
              TextField(controller: path, decoration: InputDecoration(labelText: s.path)),
              TextField(controller: uploadPath, decoration: InputDecoration(labelText: s.uploadPath)),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: Text(s.upload),
                value: upload.value,
                onChanged: (v) => upload.value = v,
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: Text(s.classical),
                value: classical.value,
                onChanged: (v) => classical.value = v,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(t.common.close)),
        FilledButton(
          onPressed: running.value ? null : run,
          child: running.value
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 8),
                    Text('${elapsed.value} s'),
                  ],
                )
              : Text(s.run),
        ),
      ],
    );
  }
}

/// D-08: what the probe found, in words: the verdict, how far the transfer went, the time and the
/// connections it used.
String describeDpiProbe(Translations t, DpiProbeResult r, double seconds) {
  final s = t.fork.dpiProbe;
  final download = r.stages.where((stage) => stage.name == 'download').firstOrNull;
  final kb = ((download?.bytes ?? 0) / 1024).round();
  final verdict = switch (r.outcome) {
    'ok' => s.outcomes.ok,
    'tcp_timeout' => s.outcomes.tcpTimeout,
    'tcp_reset' => s.outcomes.tcpReset,
    'tls_timeout' => s.outcomes.tlsTimeout,
    'tls_reset' => s.outcomes.tlsReset,
    'tls_error' => s.outcomes.tlsError,
    'freeze_16k' => s.outcomes.freeze(kb: kb),
    'stall' => s.outcomes.stall(kb: kb),
    'reset' => s.outcomes.reset(kb: kb),
    'busy' => s.outcomes.busy,
    'budget' => s.outcomes.budget,
    'error' => s.outcomes.error,
    final other => other,
  };
  return [
    verdict,
    s.summary(seconds: seconds.toStringAsFixed(1), connections: r.connections),
    for (final stage in r.stages)
      [
        '${stage.name}: ${stage.outcome}, ${(stage.bytes / 1024).toStringAsFixed(1)} KB, ${stage.millis} ms',
        if (stage.detail.isNotEmpty) '(${stage.detail})',
      ].join(' '),
  ].join('\n');
}

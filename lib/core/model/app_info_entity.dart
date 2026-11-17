import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:hiddify/core/model/environment.dart';

part 'app_info_entity.freezed.dart';

@freezed
class AppInfoEntity with _$AppInfoEntity {
  const AppInfoEntity._();

  const factory AppInfoEntity({
    required String name,
    required String version,
    required String buildNumber,
    required Release release,
    required String operatingSystem,
    required String operatingSystemVersion,
    required Environment environment,
  }) = _AppInfoEntity;

  /// For subscriptions: what Hiddify Manager needs to answer with a config of the hiddify-core format,
  /// and nothing more. The panel picks the format by a UA that starts with "HiddifyNext"
  /// (hiddifypanel/proxy_v3/client_core_auto.py) and gates features by the version after the slash
  /// (hutils/flask.py: hiddify_version >= 5 means sing-box 1.14 features); "(os)" lets it tell the
  /// platform. No OS version, device or fork name: only the panel sees it (HTTPS), but it needs no more.
  /// Then the capability tokens ([capabilities]), one word each, separated by single spaces.
  /// The app has one user agent for every request, so every way a subscription is downloaded (added,
  /// updated by hand or in the background, opened from a link) sends the same one.
  String get userAgent => userAgentFor(version, operatingSystem);

  /// What this client can read beyond what upstream Hiddify reads, told to the subscription server so it
  /// sends only what the client understands. `awg31`: AmneziaWG 3.1 endpoints (type `awg`) in the
  /// hiddify-core JSON, which this fork's core reads. A server that does not know a token ignores it;
  /// upstream Hiddify sends none (it ends its UA with " like ClashMeta v2ray sing-box").
  static const capabilities = ['awg31'];

  /// The upstream version this fork is based on: [version] without the fork's suffix (5.9.8-sp.1 -> 5.9.8).
  static String upstreamVersion(String version) => version.split(RegExp('[-+]')).first;

  static String userAgentFor(String version, String operatingSystem) =>
      ["HiddifyNext/${upstreamVersion(version)} ($operatingSystem)", ...capabilities].join(' ');

  String get presentVersion => environment == Environment.prod ? version : "$version ${environment.name}";

  /// formats app info for sharing
  String format() =>
      '''
$name v$version ($buildNumber) [${environment.name}]
${release.name} release
$operatingSystem [$operatingSystemVersion]''';
}

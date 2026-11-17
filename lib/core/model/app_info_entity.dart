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
  String get userAgent => userAgentFor(version, operatingSystem);

  /// The upstream version this fork is based on: [version] without the fork's suffix (5.9.8-sp.1 -> 5.9.8).
  static String upstreamVersion(String version) => version.split(RegExp('[-+]')).first;

  static String userAgentFor(String version, String operatingSystem) =>
      "HiddifyNext/${upstreamVersion(version)} ($operatingSystem)";

  String get presentVersion => environment == Environment.prod ? version : "$version ${environment.name}";

  /// formats app info for sharing
  String format() =>
      '''
$name v$version ($buildNumber) [${environment.name}]
${release.name} release
$operatingSystem [$operatingSystemVersion]''';
}

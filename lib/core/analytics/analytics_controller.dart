import 'package:hiddify/utils/custom_loggers.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'analytics_controller.g.dart';

const String enableAnalyticsPrefKey = "enable_analytics";

/// The fork has no analytics nor crash reporting: the Sentry SDK is not in the build, and nothing
/// can turn it on.
bool readAnalyticsEnabled(SharedPreferences preferences) => false;

@Riverpod(keepAlive: true)
class AnalyticsController extends _$AnalyticsController with AppLogger {
  @override
  Future<bool> build() async => false;

  Future<void> enableAnalytics() async {}

  Future<void> disableAnalytics() async {}
}

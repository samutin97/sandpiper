import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fpdart/fpdart.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/directories.dart';
import 'package:hiddify/core/model/environment.dart';
import 'package:hiddify/core/notification/in_app_notification_controller.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/router/dialog/dialog_notifier.dart';
import 'package:hiddify/core/router/dialog/widgets/admin_bg_service_dialogs.dart';
import 'package:hiddify/core/utils/exception_handler.dart';
import 'package:hiddify/core/utils/local_port.dart';
import 'package:hiddify/features/connection/data/local_port_repair.dart';
import 'package:hiddify/features/connection/model/connection_failure.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/data/profile_path_resolver.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/hiddifycore/core_interface/admin_permission_refused.dart';
import 'package:hiddify/hiddifycore/core_interface/core_interface_desktop_tun.dart';
import 'package:hiddify/hiddifycore/core_interface/core_interface_macos.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pbenum.dart' as hcore;
import 'package:hiddify/hiddifycore/hiddify_core_service.dart';
import 'package:hiddify/singbox/model/core_status.dart';
import 'package:hiddify/singbox/model/singbox_config_enum.dart';
import 'package:hiddify/singbox/model/singbox_config_option.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:meta/meta.dart';
import 'package:rxdart/rxdart.dart';

abstract interface class ConnectionRepository {
  SingboxConfigOption? get configOptionsSnapshot;

  TaskEither<ConnectionFailure, Unit> setup();
  Stream<ConnectionStatus> watchConnectionStatus();

  /// Whether the core is applying a new config without a restart; the connection stays up
  /// (watchConnectionStatus keeps reporting it as connected).
  TaskEither<ConnectionFailure, Unit> connect(ProfileEntity activeProfile, bool disableMemoryLimit);
  TaskEither<ConnectionFailure, Unit> disconnect();
  TaskEither<ConnectionFailure, Unit> reconnect(ProfileEntity activeProfile, bool disableMemoryLimit);
}

class ConnectionRepositoryImpl with ExceptionHandler, InfraLogger implements ConnectionRepository {
  ConnectionRepositoryImpl({
    required this.ref,
    required this.directories,
    required this.singbox,
    required this.configOptionRepository,
    required this.profilePathResolver,
  }) {
    // the core's own line about the failed bind is not a fatal one while the repair deals with it
    singbox.handledLocalBind = _handledLocalBind;
  }

  final Ref ref;

  final Directories directories;
  final HiddifyCoreService singbox;

  final ConfigOptionRepository configOptionRepository;
  final ProfilePathResolver profilePathResolver;

  SingboxConfigOption? _configOptionsSnapshot;
  @override
  SingboxConfigOption? get configOptionsSnapshot => _configOptionsSnapshot;

  bool _initialized = false;

  @override
  TaskEither<ConnectionFailure, Unit> setup() {
    if (_initialized) return TaskEither.of(unit);
    return exceptionHandler(() {
      loggy.debug("setting up singbox");

      return singbox
          .setup()
          .map((r) {
            _initialized = true;
            return r;
          })
          .mapLeft(UnexpectedConnectionFailure.new)
          .run();
    }, UnexpectedConnectionFailure.new);
  }

  @override
  Stream<ConnectionStatus> watchConnectionStatus() {
    final core = singbox.watchStatus().where((event) => !_heldBack(event)).map(
      (event) => _hiddenForPortRepair(event)
          ? const Connecting()
          : switch (event) {
              // the user stopped the connect: a failure of it that is still on its way is not theirs to see
              CoreStopped() => Disconnected(_cancelled ? null : event.getCoreAlert()),
              CoreStarting() => const Connecting(),
              CoreWaiting() => const Waiting(),
              CoreNoAvailableProxies() => const NoAvailableProxies(),
              CoreStarted() => const Connected(),
              CoreStopping() => const Disconnecting(),
              CoreHotReloading() => const HotReloading(),
            },
    );
    return Rx.merge([core, _portRetryOutcome.stream]);
  }

  /// Set while a connect runs: the VPN choice dialog was shown, and then the administrator prompt
  /// was refused or the user stopped waiting for it.
  var _vpnChoiceShown = false;
  var _adminRefused = false;

  /// Connects; when the user agreed to VPN mode in the choice dialog but then refused the
  /// administrator prompt (or stopped waiting for it), the choice is offered again instead of an
  /// error, so they can try again or switch to system proxy mode.
  @override
  TaskEither<ConnectionFailure, Unit> connect(ProfileEntity activeProfile, bool disableMemoryLimit) => setup().flatMap(
    (_) => TaskEither(() async {
      final generation = _armPortRepair(activeProfile, disableMemoryLimit);
      Either<ConnectionFailure, Unit>? outcome;
      try {
        while (true) {
          _vpnChoiceShown = false;
          _adminRefused = false;
          var result = await _connectOnce(activeProfile, disableMemoryLimit).run();
          // a start that reports its failure as its result too (Android: the core started in the
          // background) waits for the repair, and its outcome is the retry's
          if (result case Left(value: final failure) when generation == _connectGeneration) {
            if (_startPortRepair("$failure") case final retry?) result = await retry;
          }
          if (result.isRight() || !_vpnChoiceShown || !_adminRefused) return outcome = result;
          loggy.info("administrator permission was not given, offering the choice again");
        }
      } finally {
        await _settleConnect(generation, outcome);
      }
    }),
  );

  // D9-01. A connect the user or the autostart asks for may repair one local port: its start fails
  // to open a port the app picked at random (Windows reserves ranges of ports and moves them at a
  // reboot; another program may hold one). On the desktop and macOS the start returns once the core
  // has the request, and the failure comes after, on the status stream: that is where it is
  // recognised (on Android the start also returns it, and connect() waits for the repair). The
  // failure, the stop of the failed core that the core service makes, and the report of the
  // failure once more after that stop read as connecting; once the stop is over, a new port is
  // saved and the start runs once more. If that one fails, its failure shows as usual.

  /// Counts the connects and disconnects: a repair belongs to the connect that armed it.
  var _connectGeneration = 0;

  // D11-01: what the user sees while a connect runs is "connecting", until its outcome. A plain stop
  // in that time is not the outcome: the core service stops a core that failed to start (the first
  // attempt of a repair), the platform reports its stop before the core's failure, and a status
  // listener set up again is answered with the state the core was in before the start.

  /// Set from the start of a connect until it returned (and the events it published were handled).
  var _connecting = false;

  /// A plain stop was held back while the connect ran, and nothing has come after it.
  var _stopHeldBack = false;

  /// The user disconnected a connect that had not ended: its failure, if it still comes, is not shown.
  var _cancelled = false;

  /// A stop without a failure: what a core says when it was stopped, as opposed to when it failed. The
  /// message of the one that comes off the wire is empty, not null.
  static bool _isPlainStop(CoreStatus event) =>
      event is CoreStopped && event.alert == null && (event.message ?? "").isEmpty;

  /// Whether [event] is a plain stop of a connect that runs (and has no repair under way: that one
  /// reads such stops as connecting itself); it is then not published.
  bool _heldBack(CoreStatus event) {
    if (!_isPlainStop(event)) {
      _stopHeldBack = false;
      return false;
    }
    if (!_connecting || _replacedPort != null) return false;
    _stopHeldBack = true;
    return true;
  }

  /// The connect [generation] returned with [outcome]: a stop that was held back and was the last
  /// word is its outcome after all (the core stopped, with nothing to say about it).
  Future<void> _settleConnect(int generation, Either<ConnectionFailure, Unit>? outcome) async {
    // the events the start published just before it returned are still on their way
    await Future<void>.delayed(Duration.zero);
    if (generation != _connectGeneration || _portRepairing) return;
    _connecting = false;
    if (_stopHeldBack) {
      _stopHeldBack = false;
      // a failure is shown by whoever got it
      if (outcome != null && outcome.isRight()) _portRetryOutcome.add(const Disconnected());
    }
  }

  /// The connect armed may still repair a port: until its core starts, fails otherwise, or one
  /// repair began.
  var _portRepairArmed = false;
  ({ProfileEntity profile, bool disableMemoryLimit})? _portRepairConnect;

  /// The port given up: a report of its failure is old news until the next connect.
  int? _replacedPort;

  /// The reports of the given-up port's failure seen since the repair began.
  var _replacedPortReports = 0;

  /// Set from the start of a repair until its retry started: the failed core's stop reads as
  /// connecting.
  var _portRepairing = false;

  /// Completes when the failed core's stop is over: a plain stop, or the failure reported once more.
  Completer<void>? _failedCoreStopped;

  /// The retry of the armed connect, once it began.
  Future<Either<ConnectionFailure, Unit>>? _portRetry;

  /// A retry that failed, for the status stream: on the desktop nobody waits for the retry.
  final _portRetryOutcome = StreamController<ConnectionStatus>.broadcast();

  int _armPortRepair(ProfileEntity profile, bool disableMemoryLimit) {
    _endPortRepair();
    _portRepairArmed = true;
    _connecting = true;
    _stopHeldBack = false;
    _cancelled = false;
    _portRepairConnect = (profile: profile, disableMemoryLimit: disableMemoryLimit);
    return _connectGeneration;
  }

  /// Ends what a connect armed (a disconnect, or another connect): a repair waiting for the failed
  /// core's stop gives up at once.
  void _endPortRepair() {
    _connectGeneration++;
    _portRepairArmed = false;
    _portRetry = null;
    _replacedPort = null;
    _replacedPortReports = 0;
    _portRepairing = false;
    _connecting = false;
    _stopHeldBack = false;
    _failedCoreStopped?.completeOnce();
    _failedCoreStopped = null;
  }

  /// Whether [event] belongs to a port repair (it then reads as connecting); it starts the repair
  /// when it is the failure of the armed connect's start on a local port the app picked.
  bool _hiddenForPortRepair(CoreStatus event) {
    if (_replacedPort case final replaced?) {
      if (event case CoreStopped(:final message) when failedLocalBind(message ?? "") == replaced) {
        // reported once by the core, once more when the core service has stopped the failed core
        if (++_replacedPortReports >= 2) _failedCoreStopped?.completeOnce();
        return true;
      }
      if (_portRepairing) {
        switch (event) {
          case CoreStopping():
            return true;
          case CoreStopped() when _isPlainStop(event):
            _failedCoreStopped?.completeOnce();
            return true;
          default:
        }
      }
      return false;
    }
    if (!_portRepairArmed) return false;
    switch (event) {
      case CoreStopped(:final message, :final alert):
        if (_startPortRepair(message ?? "", reported: true) != null) return true;
        // the start failed otherwise: no repair for this connect
        if (alert != null) _portRepairArmed = false;
      case CoreStarted() || CoreWaiting() || CoreNoAvailableProxies():
        _portRepairArmed = false;
      default:
    }
    return false;
  }

  /// Starts the repair of the armed connect when [message] is a failure to open a local port the
  /// app picked ([reported]: on the status stream), and returns its retry; the one already under
  /// way, if any; null otherwise.
  Future<Either<ConnectionFailure, Unit>>? _startPortRepair(String message, {bool reported = false}) {
    if (_portRetry case final retry?) return retry;
    if (!_portRepairArmed) return null;
    final key = _portRepair.failedKey(message);
    final connect = _portRepairConnect;
    if (key == null || connect == null) return null;
    _portRepairArmed = false;
    _replacedPort = failedLocalBind(message);
    _replacedPortReports = reported ? 1 : 0;
    _portRepairing = true;
    final stopped = _failedCoreStopped = Completer<void>();
    return _portRetry = _repairPortAndConnect(key, connect, stopped.future, _connectGeneration);
  }

  /// How long a repair waits for the failed core's stop to be over before it starts again.
  static const portRepairStopWait = Duration(seconds: 3);

  Future<Either<ConnectionFailure, Unit>> _repairPortAndConnect(
    String key,
    ({ProfileEntity profile, bool disableMemoryLimit}) connect,
    Future<void> failedCoreStopped,
    int generation,
  ) async {
    // the core service stops the failed core when the core reports the failure: a start before that
    // stop is over would race it
    await failedCoreStopped.timeout(portRepairStopWait, onTimeout: () {});
    // a disconnect, or another connect, came meanwhile
    if (generation != _connectGeneration) return right(unit);
    await _portRepair.replace(key);
    // the user disconnected while the port was being replaced
    if (generation != _connectGeneration) return right(unit);
    final Either<ConnectionFailure, Unit> result;
    try {
      result = await _connectOnce(
        connect.profile,
        connect.disableMemoryLimit,
        cancelled: () => generation != _connectGeneration,
      ).run();
    } finally {
      if (generation == _connectGeneration) _portRepairing = false;
    }
    if (generation == _connectGeneration) {
      if (result case Left(value: final failure)) _portRetryOutcome.add(Disconnected(failure));
    }
    await _settleConnect(generation, result);
    return result;
  }

  /// D9-01: the local ports the app picked at random (the local proxy, the Clash API) and may pick
  /// again when the core cannot open them; the others the user set keep theirs.
  late final _portRepair = LocalPortRepair(
    ports: () => {
      "mixed-port": ref.read(ConfigOptions.mixedPort),
      "clash-api-port": ref.read(ConfigOptions.clashApiPort),
      "lan-sharing-port": ref.read(ConfigOptions.lanSharingPort),
      "tproxy-port": ref.read(ConfigOptions.tproxyPort),
      "redirect-port": ref.read(ConfigOptions.redirectPort),
      "direct-port": ref.read(ConfigOptions.directPort),
    },
    repairable: const {"mixed-port", "clash-api-port"},
    save: (key, port) => switch (key) {
      "mixed-port" => ref.read(ConfigOptions.mixedPort.notifier).update(port),
      _ => ref.read(ConfigOptions.clashApiPort.notifier).update(port),
    },
    onRepaired: (key, from, to) => loggy.warning("the core could not open the local port $from ($key): using $to"),
  );

  /// One start; [cancelled] is asked right before it, and the start is then not made.
  TaskEither<ConnectionFailure, Unit> _connectOnce(
    ProfileEntity activeProfile,
    bool disableMemoryLimit, {
    bool Function()? cancelled,
  }) => applyConfigOption(activeProfile).flatMap(
    (_) =>
        TaskEither.tryCatch(() async {
          await _prepareAdminBgService(activeProfile);
          return unit;
        }, (err, st) => err is ConnectionFailure ? err : ConnectionFailure.unexpected(err, st)).flatMap(
          (_) => cancelled?.call() ?? false
              ? TaskEither<ConnectionFailure, Unit>.of(unit)
              : singbox.start(profilePathResolver.file(activeProfile.id).path, activeProfile.name, disableMemoryLimit),
        ),
  );

  /// Whether the core's own [message] reports a failure to open the local port that the repair of the
  /// connect deals with: the armed connect's port, or the one given up. The line is then logged as a
  /// warning, as the failure is handled (the log read it as fatal, though the app went on).
  bool _handledLocalBind(String message) {
    final port = failedLocalBind(message);
    if (port == null) return false;
    if (_replacedPort == port) return true;
    return _portRepairArmed && _portRepair.failedKey(message) != null;
  }

  /// Modes A/B/C: ask fg core (Win/Linux) or native tunnel-service status (macOS), show consent.
  Future<void> _prepareAdminBgService(ProfileEntity profile) async {
    final options = _configOptionsSnapshot;
    if (options == null) return;

    if (Platform.isMacOS) {
      await _prepareMacosAdminBgService(profile, options);
      return;
    }
    if (!Platform.isWindows && !Platform.isLinux) return;
    final core = singbox.core;
    if (core is! CoreInterfaceDesktopTun) return;

    final pref = profile.userOverride?.adminPreference ?? UserAdminPreference.unset;
    final serviceMode = _serviceMode(options);

    final decision = await core.needAdminBgService(
      serviceMode: serviceMode,
      settingsJson: jsonEncode(options.toJson()),
      adminPreference: switch (pref) {
        UserAdminPreference.unset => hcore.AdminPreference.ADMIN_PREFERENCE_UNSET,
        UserAdminPreference.preferAdmin => hcore.AdminPreference.ADMIN_PREFERENCE_PREFER_ADMIN,
        UserAdminPreference.preferNoAdmin => hcore.AdminPreference.ADMIN_PREFERENCE_PREFER_NO_ADMIN,
      },
    );

    final dialogs = ref.read(dialogNotifierProvider.notifier);
    var useAdminBg = false;
    var stripPrivileged = false;
    var needsElevation = false;

    switch (decision.decision) {
      case hcore.AdminBgServiceDecision.ADMIN_BG_SERVICE_NO:
        useAdminBg = false;
        // preferNoAdmin already decided in Go; still strip privileged features for this run.
        if (pref == UserAdminPreference.preferNoAdmin && decision.adminNeededProxies.isNotEmpty) {
          stripPrivileged = true;
        }
      case hcore.AdminBgServiceDecision.ADMIN_BG_SERVICE_ALREADY_CONNECTED:
        useAdminBg = true;
      case hcore.AdminBgServiceDecision.ADMIN_BG_SERVICE_NEEDS_ADMIN:
        if (options.enableTun && pref == UserAdminPreference.unset) {
          final choice = await dialogs.showVpnAdminBgService();
          _vpnChoiceShown = true;
          if (choice == VpnAdminBgDialogResult.switchToSystemProxy) return _switchToSystemProxy(profile);
          if (choice != VpnAdminBgDialogResult.connectWithAdmin) {
            throw const ConnectionFailure.missingPrivilege();
          }
        }
        useAdminBg = true;
        needsElevation = true;
      case hcore.AdminBgServiceDecision.ADMIN_BG_SERVICE_OPTIONAL_PROXY_NEED_ADMIN:
        final (choice, neverAsk) = await dialogs.showProxyAdminBgService(proxies: decision.adminNeededProxies);
        if (choice == ProxyAdminBgDialogResult.cancel) {
          throw const ConnectionFailure.missingPrivilege();
        }
        if (choice == ProxyAdminBgDialogResult.runAsAdmin) {
          useAdminBg = true;
          needsElevation = true;
          if (neverAsk) {
            await _persistAdminPreference(profile, UserAdminPreference.preferAdmin);
          }
        } else {
          stripPrivileged = true;
          if (neverAsk) {
            await _persistAdminPreference(profile, UserAdminPreference.preferNoAdmin);
          }
        }
      default:
        useAdminBg = false;
    }

    core.useAdminBgService = useAdminBg;
    // the waiting dialog belongs to VPN mode only; a proxy mode that needs the service just shows
    // the system's own prompt
    core.wrapAdminElevation = needsElevation && options.enableTun
        ? (work) async {
            try {
              final ok = await dialogs.runWhileVpnAdminWaiting(work);
              if (!ok) _adminRefused = true;
              return ok;
            } on AdminPermissionRefused {
              _adminRefused = true;
              rethrow;
            }
          }
        : null;

    if (stripPrivileged) {
      final stripped = options.copyWith(tlsTricks: options.tlsTricks.copyWith(mixedSniCase: false));
      _configOptionsSnapshot = stripped;
      final optionsResult = await singbox.changeOptions(stripped).run();
      optionsResult.match((error) => throw ConnectionFailure.unexpected(error), (_) {});
    } else if (useAdminBg) {
      // Re-apply so setOptions sees useAdminBgService.
      final optionsResult = await singbox.changeOptions(options).run();
      optionsResult.match((error) => throw ConnectionFailure.unexpected(error), (_) {});
    }
  }

  /// macOS unsigned builds: root TunnelService / admin_bgservice. Consent before the password prompt.
  Future<void> _prepareMacosAdminBgService(ProfileEntity profile, SingboxConfigOption options) async {
    final core = singbox.core;
    if (core is! CoreInterfaceMacOS) return;
    // the App Store build never asks for root, whatever the native side reports
    if (Release.read() == Release.appStore) return;
    // Network Extension builds do not use the admin password install path.
    if (!core.tunnelServiceAvailable || !options.enableTun) return;

    final dialogs = ref.read(dialogNotifierProvider.notifier);
    final pref = profile.userOverride?.adminPreference ?? UserAdminPreference.unset;

    if (core.tunnelServiceReady) return;

    // Refusing the password prompt, or stopping the wait for it, goes back to the choice.
    while (true) {
      if (pref == UserAdminPreference.unset) {
        final choice = await dialogs.showVpnAdminBgService();
        if (choice == VpnAdminBgDialogResult.switchToSystemProxy) return _switchToSystemProxy(profile);
        if (choice != VpnAdminBgDialogResult.connectWithAdmin) {
          throw const ConnectionFailure.missingPrivilege();
        }
      }
      if (await _installMacosAdminBgService(core, dialogs)) return;
      // no choice to go back to: the profile always asks for administrator permission
      if (pref != UserAdminPreference.unset) throw const ConnectionFailure.missingPrivilege();
      loggy.info("administrator permission was not given, offering the choice again");
    }
  }

  /// Installs the macOS tunnel service behind the password prompt: true once installed, false when
  /// the user refused the prompt or stopped waiting for it.
  Future<bool> _installMacosAdminBgService(CoreInterfaceMacOS core, DialogNotifier dialogs) async {
    try {
      if (await dialogs.runWhileVpnAdminWaiting(core.installAdminBgService())) return true;
      try {
        await core.stop();
      } catch (_) {}
      return false;
    } catch (error) {
      final message = error.toString().toLowerCase();
      if (message.contains('cancel') || message.contains('permission') || message.contains('denied')) return false;
      throw ConnectionFailure.unexpected(error);
    }
  }

  /// The user chose the system proxy over asking for an administrator: it becomes the service mode,
  /// and this connect goes on in it. The connection is not running yet, so the change starts no
  /// reconnect of its own.
  Future<void> _switchToSystemProxy(ProfileEntity profile) async {
    loggy.info("switching to system proxy mode instead of asking for administrator");
    await ref.read(ConfigOptions.serviceMode.notifier).update(ServiceMode.systemProxy);
    (await applyConfigOption(profile).run()).match((failure) => throw failure, (_) {});
    final t = ref.read(translationsProvider).requireValue;
    ref.read(inAppNotificationControllerProvider).showInfoToast(t.dialogs.adminBgService.vpnNeedsAdmin.switched);
    await _prepareAdminBgService(profile);
  }

  Future<void> _persistAdminPreference(ProfileEntity profile, UserAdminPreference preference) async {
    final override = (profile.userOverride ?? const UserOverride()).copyWith(adminPreference: preference);
    final updated = profile.copyWith(userOverride: override);
    final profiles = ref.read(profileRepositoryProvider).requireValue;
    final raw = await profiles.getRawConfig(profile.id).run();
    await raw.match(
      (l) {
        loggy.warning('could not persist admin preference: $l');
      },
      (content) async {
        final result = await profiles.offlineUpdate(updated, content).run();
        result.match((l) => loggy.warning('could not persist admin preference: $l'), (_) {});
      },
    );
  }

  @override
  TaskEither<ConnectionFailure, Unit> disconnect() {
    // a connect that has not ended is cancelled, and its failure is not shown
    final cancels = _connecting || _portRepairArmed || _portRepairing || _replacedPort != null;
    // no port repair outlives a disconnect
    _endPortRepair();
    _cancelled = cancels;
    return singbox.stop().mapLeft(UnexpectedConnectionFailure.new);
  }

  static String _serviceMode(SingboxConfigOption options) =>
      options.routerMode ? 'router' : (options.enableTun ? 'vpn' : (options.setSystemProxy ? 'system-proxy' : 'proxy'));

  /// Windows and Linux: the core runs in this process for proxy modes and in admin_bgservice for
  /// VPN, so a new service mode moves it. A hot reload would only change the core already running
  /// (proxy → VPN removed the system proxy and started no TUN), so the connection is stopped and
  /// made again, which also asks for admin consent.
  @override
  TaskEither<ConnectionFailure, Unit> reconnect(ProfileEntity activeProfile, bool disableMemoryLimit) {
    final before = _configOptionsSnapshot;
    return applyConfigOption(activeProfile).flatMap((_) {
      final after = _configOptionsSnapshot;
      if (singbox.core is CoreInterfaceDesktopTun &&
          before != null &&
          after != null &&
          _serviceMode(before) != _serviceMode(after)) {
        loggy.info("service mode changed from ${_serviceMode(before)} to ${_serviceMode(after)}, reconnecting");
        return disconnect().flatMap((_) => connect(activeProfile, disableMemoryLimit));
      }
      // hot reload when possible, restart otherwise
      return singbox
          .reload(profilePathResolver.file(activeProfile.id).path, activeProfile.name, disableMemoryLimit)
          .mapLeft(UnexpectedConnectionFailure.new);
    });
  }

  @visibleForTesting
  TaskEither<ConnectionFailure, Unit> applyConfigOption(ProfileEntity prof) =>
      TaskEither.fromEither(configOptionRepository.fullOptionsOverrided(prof.profileOverride()))
          .mapLeft((l) => ConnectionFailure.invalidConfigOption(null, l))
          .flatMap(
            (overridedOptions) => TaskEither.tryCatch(() async {
              if (!overridedOptions.chainStatus.isOff()) {
                final isWarpLicenseAgreed = ref.read(Preferences.warpConsentGiven) == true;
                final isWarpEnabled = [
                  overridedOptions.unblocker.mode,
                  overridedOptions.extraSecurity.mode,
                ].any((key) => ChainMode.fromKey(key)?.isWarp() ?? false);
                if (!isWarpLicenseAgreed && isWarpEnabled) {
                  final isAgreed = await ref.read(dialogNotifierProvider.notifier).showWarpLicense();
                  if (isAgreed == true) {
                    await ref.read(Preferences.warpConsentGiven.notifier).update(true);
                    // return (await applyConfigOption(prof).run()).match((l) => throw l, (_) => unit);
                  } else {
                    throw const MissingWarpLicense();
                  }
                }

                final isPsiphonLicenseAgreed = ref.read(Preferences.psiphonConsentGiven) == true;
                final isPsiphonEnabled = [
                  overridedOptions.unblocker.mode,
                  overridedOptions.extraSecurity.mode,
                ].any((key) => ChainMode.fromKey(key)?.isPsiphon() ?? false);
                if (!isPsiphonLicenseAgreed && isPsiphonEnabled) {
                  final isAgreed = await ref.read(dialogNotifierProvider.notifier).showPsiphonLicense();
                  if (isAgreed == true) {
                    await ref.read(Preferences.psiphonConsentGiven.notifier).update(true);
                  } else {
                    throw const MissingPsiphonLicense();
                  }
                }
              }

              _configOptionsSnapshot = overridedOptions;
              final optionsResult = await singbox.changeOptions(overridedOptions).run();
              optionsResult.match((error) => throw ConnectionFailure.unexpected(error), (_) {});
              return unit;
            }, (err, st) => err is ConnectionFailure ? err : ConnectionFailure.unexpected(err, st)),
          );
}

extension on Completer<void> {
  void completeOnce() {
    if (!isCompleted) complete();
  }
}

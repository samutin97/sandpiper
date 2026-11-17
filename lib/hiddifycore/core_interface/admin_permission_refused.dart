/// The user did not give administrator permission for VPN mode: the system prompt was refused or
/// dismissed, or the user stopped waiting for it. Not a failure of the service itself, so the app
/// offers the choice between VPN and system proxy mode again instead of an error.
class AdminPermissionRefused implements Exception {
  const AdminPermissionRefused();

  @override
  String toString() => 'Administrator permission was not given, so VPN mode could not connect.';
}

/// The VPN service could not be installed or started, with the reason to show the user as it is
/// (a [StateError] would read "Bad state: ...").
class VpnServiceFailure implements Exception {
  const VpnServiceFailure(this.message);

  final String message;

  /// No pkexec to ask for the administrator password: a minimal desktop, or an AppImage on one.
  static const noAdminPrompt = VpnServiceFailure(
    'VPN mode needs pkexec to ask for the administrator password, and it is not installed: '
    'install the pkexec package (polkit) and try again, or use system proxy mode.',
  );

  /// pkexec found no polkit agent to show its prompt: the app was started from a terminal or over SSH,
  /// or the desktop runs none (hiddify-app#2582).
  static const noAdminAgent = VpnServiceFailure(
    'Could not ask for the administrator password: no authentication agent is running, as when Hiddify '
    'is started from a terminal or over SSH. Start Hiddify from the applications menu and try again.',
  );

  /// B-02: the portable build of Windows runs from a folder its user can write to, and the service
  /// would run that folder's HiddifyAdmin.exe as SYSTEM at every boot: any program of the user could
  /// replace it. It installs no service; VPN mode runs only in an app started as administrator.
  static const portable = VpnServiceFailure(
    'The portable build installs no VPN service: start it as administrator for VPN mode, use proxy '
    'mode, or install the setup build.',
  );

  @override
  String toString() => message;
}

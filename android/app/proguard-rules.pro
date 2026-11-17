# Sandpiper release rules (Flutter adds this file to its own: FlutterPlugin.kt, proguard-rules.pro).

# D-04: no debug or verbose logging in a release, from any code in the APK. The app_links plugin
# logged every deep link whole at Log.d ("Handled intent: ... data: sandpiper://import/<the
# subscription URL with its token>"), and logcat is readable over adb and goes into bug reports.
# Info and above stay (the app logs nothing secret there).
-assumenosideeffects class android.util.Log {
    public static int d(...);
    public static int v(...);
}

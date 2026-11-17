#!/usr/bin/env bash
# Sandpiper (fork of Hiddify 5.9.8, branch hardened) for Android: one command, on a Windows PC
# (Git Bash). Installs nothing in the system: toolchain/ (JDK 17, Flutter 3.38.5, pub-cache, Gradle
# home) and the existing Android SDK. Releases are built by .github/workflows/sandpiper-release.yml;
# this script is the local equivalent.
#
#   VPN=<work folder with toolchain/, src/, build/, secrets/> bash scripts/build-sandpiper-android.sh
#
# Result: dist/android/Sandpiper-<version>-{arm64-v8a,x86_64,universal}-release.apk (signed with
# the release key, v2+v3), Sandpiper-<version>-x86_64-debug.apk (emulator), SHA256SUMS-sandpiper.txt,
# and the static manifest check of each APK (manifest-*.md).
#
# Variables:
#   SRC       repository with the branch `hardened`          [VPN/src/hiddify-app]
#   WORK      working clone (made from SRC when missing)       [VPN/build/hiddify-hardened]
#   CORE      hardened | official                              [hardened]
#             hardened: CORE_AAR (the fork's own core) checked against its SHA256SUMS.txt
#             official: hiddify-core v5.9.8 from GitHub, checked against dependencies.properties
#   CORE_AAR  [VPN/build/artifacts/hiddify-core-hardened/hiddify-core.aar] (never lean/)
#   KEYSTORE / KEYPASS_FILE / KEYALIAS  the release key  [secrets/android-signing/sandpiper-release.*, sandpiper]
#   OUT       [VPN/dist/android]
#   DEBUG     1 = also the x86_64 debug APK for the emulator  [1]
#
# Integration of a new core build is this one command:
#   CORE_AAR=<path>/hiddify-core.aar bash scripts/build-sandpiper-android.sh
# (its SHA-256 must be in SHA256SUMS.txt next to it, or given as CORE_SHA256).
set -euo pipefail

VPN="${VPN:?set VPN to the work folder (toolchain/, src/, build/, secrets/)}"
TC="$VPN/toolchain"
SRC="${SRC:-$VPN/src/hiddify-app}"
WORK="${WORK:-$VPN/build/hiddify-hardened}"
CORE="${CORE:-hardened}"
CORE_AAR="${CORE_AAR:-$VPN/build/artifacts/hiddify-core-hardened/hiddify-core.aar}"
# the hardened core this version of the app is made for (1a2f934, 5.9.8-sp.5: the choice of a proxy by
# the subscription server's ranking, the tiered group and its state for the app); a newer aar is taken
# only with its own CORE_SHA256
CORE_PINNED_SHA256="1e13507530715daf3dfa48a4b9f04229a94092591cfbae008dc6e6e8a6d1510b"
KEYSTORE="${KEYSTORE:-$VPN/secrets/android-signing/sandpiper-release.jks}"
KEYPASS_FILE="${KEYPASS_FILE:-$VPN/secrets/android-signing/sandpiper-release.password.txt}"
KEYALIAS="${KEYALIAS:-sandpiper}"
OUT="${OUT:-$VPN/dist/android}"
DEBUG="${DEBUG:-1}"
LOG="${LOG:-$VPN/build/logs/sandpiper}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
t0=$(date +%s)
step() { echo; echo "=== [$(( $(date +%s)-t0 ))s] $*"; }
# pub.dev / storage.googleapis.com through the local proxy answer 403 now and then: try again
retry() { local n=$1; shift; local i; for i in $(seq 1 "$n"); do "$@" && return 0; echo "  (attempt $i/$n failed, again)"; sleep 3; done; return 1; }

step "environment"
source "$TC/env-flutter.sh" >/dev/null
export GRADLE_USER_HOME="$(cygpath -m "$TC/hiddify-extra/gradle-home")"
mkdir -p "$LOG" "$OUT"
flutter config --no-analytics >/dev/null 2>&1 || true
AAPT2="$(ls -d "$ANDROID_HOME"/build-tools/*/ | sort -V | tail -1)aapt2"
APKSIGNER="$(ls -d "$ANDROID_HOME"/build-tools/*/ | sort -V | tail -1)lib/apksigner.jar"

if [ ! -d "$WORK/.git" ]; then
  step "clone $SRC (hardened) -> $WORK"
  git clone --local -b hardened -c core.autocrlf=false "$SRC" "$WORK"
  git -C "$WORK" config core.autocrlf false
  # the core's sources are not needed for the APK; the submodule only for the protos and the Makefile
  git -C "$WORK" -c protocol.file.allow=always -c submodule.hiddify-core.url="$SRC/hiddify-core" submodule update --init || true
fi
cd "$WORK"
COMMIT="$(git rev-parse --short=7 HEAD)"
VERSION="$(sed -n 's/^version: *\([^+]*\).*/\1/p' pubspec.yaml | tr -d '\r')"
echo "commit $COMMIT, version $VERSION"

step "flutter pub get, code generation, translations"
retry 30 flutter pub get >"$LOG/pubget.log" 2>&1 || { tail -20 "$LOG/pubget.log"; exit 1; }
dart run build_runner build --delete-conflicting-outputs >"$LOG/build_runner.log" 2>&1 || { tail -30 "$LOG/build_runner.log"; exit 1; }
dart run slang >"$LOG/slang.log" 2>&1 || { tail -20 "$LOG/slang.log"; exit 1; }

step "core ($CORE), checked by SHA-256"
rm -f android/app/libs/hiddify-core.aar
if [ "$CORE" = hardened ]; then
  case "$CORE_AAR" in */lean/*) echo "the lean core is not for this build" >&2; exit 1;; esac
  LISTED="$(sed -n 's/^\([0-9a-f]\{64\}\) \*\{0,1\}hiddify-core\.aar$/\1/p' "$(dirname "$CORE_AAR")/SHA256SUMS.txt" | head -1)"
  if [ -z "${CORE_SHA256:-}" ]; then
    CORE_SHA256="$CORE_PINNED_SHA256"
    [ "$LISTED" = "$CORE_SHA256" ] || { echo "SHA256SUMS.txt next to the aar lists $LISTED, the build pins $CORE_SHA256" >&2; exit 1; }
  fi
  CORE_AAR="$CORE_AAR" CORE_SHA256="$CORE_SHA256" bash scripts/fetch-core.sh android android/app/libs
  CORE_LABEL="hardened $(head -1 "$(dirname "$CORE_AAR")/CORE_COMMIT.txt" | cut -c1-40)"
else
  bash scripts/fetch-core.sh android android/app/libs
  CORE_LABEL="official v$(sed -n 's/^core.version=//p' dependencies.properties | tr -d '\r')"
fi
CORE_SUM="$(sha256sum android/app/libs/hiddify-core.aar | cut -d' ' -f1)"

step "release key (android/key.properties, outside the repository)"
[ -s "$KEYSTORE" ] && [ -s "$KEYPASS_FILE" ] || { echo "no release key: $KEYSTORE" >&2; exit 1; }
PW="$(cat "$KEYPASS_FILE")"
printf '%s=%s\n' storeFile "$(cygpath -m "$KEYSTORE")" storePassword "$PW" keyPassword "$PW" keyAlias "$KEYALIAS" > android/key.properties
unset PW
trap 'rm -f "$WORK/android/key.properties"' EXIT

step "clean"
flutter clean >"$LOG/clean.log" 2>&1 || true
retry 10 flutter pub get >"$LOG/pubget2.log" 2>&1 || { tail -20 "$LOG/pubget2.log"; exit 1; }

step "release APKs (arm64-v8a, armeabi-v7a, x86_64 and universal; CHANNEL=prod, lib/main_prod.dart)"
flutter build apk --release --target lib/main_prod.dart \
  --target-platform android-arm,android-arm64,android-x64 \
  --dart-define=commit="$COMMIT" >"$LOG/release.log" 2>&1 || { tail -40 "$LOG/release.log"; exit 1; }
F=build/app/outputs/flutter-apk
ls "$F"

if [ "$DEBUG" = 1 ]; then
  step "debug APK x86_64 (emulator)"
  flutter build apk --debug --target lib/main.dart --target-platform android-x64 \
    --dart-define=commit="$COMMIT" >"$LOG/debug.log" 2>&1 || { tail -40 "$LOG/debug.log"; exit 1; }
fi

step "collect -> $OUT"
rm -f "$OUT"/Sandpiper-*.apk "$OUT"/manifest-*.md
cp "$F/app-arm64-v8a-release.apk" "$OUT/Sandpiper-$VERSION-arm64-v8a-release.apk"
cp "$F/app-x86_64-release.apk"    "$OUT/Sandpiper-$VERSION-x86_64-release.apk"
cp "$F/app-release.apk"           "$OUT/Sandpiper-$VERSION-universal-release.apk"
[ -f "$F/app-armeabi-v7a-release.apk" ] && cp "$F/app-armeabi-v7a-release.apk" "$OUT/Sandpiper-$VERSION-armeabi-v7a-release.apk"
[ "$DEBUG" = 1 ] && cp "$F/app-debug.apk" "$OUT/Sandpiper-$VERSION-x86_64-debug.apk"

step "signatures and manifests"
status=0
for apk in "$OUT"/Sandpiper-*.apk; do
  name="$(basename "$apk" .apk)"
  java -jar "$(cygpath -m "$APKSIGNER")" verify --verbose --print-certs "$(cygpath -m "$apk")" >"$OUT/signature-$name.txt" 2>&1 || status=1
  python -I "$HERE/check-sandpiper-apk.py" "$AAPT2" "$(cygpath -m "$apk")" --report "$OUT/manifest-$name.md" >/dev/null || { echo "forbidden names in $name"; status=1; }
done
"$AAPT2" dump badging "$(cygpath -m "$OUT/Sandpiper-$VERSION-arm64-v8a-release.apk")" > "$OUT/badging-arm64-v8a.txt" 2>/dev/null || true
( cd "$OUT" && sha256sum Sandpiper-*.apk > SHA256SUMS-sandpiper.txt && cat SHA256SUMS-sandpiper.txt )
{
  echo "app commit: $COMMIT ($VERSION)"
  echo "core: $CORE_LABEL"
  echo "core aar sha256: $CORE_SUM"
  echo "built: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$OUT/BUILD-INFO.txt"
cat "$OUT/BUILD-INFO.txt"
step "done in $(( $(date +%s)-t0 )) s"
exit $status

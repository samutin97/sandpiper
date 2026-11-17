# Sandpiper

**Sandpiper is a modified version of [Hiddify](https://github.com/hiddify/hiddify-app)** (app 5.9.8), released under
the same license, [Hiddify Extended GPL v3](LICENSE.md). All credit for the original app goes to the Hiddify team;
this fork is a private, non-commercial build for a small group. It is not published in any app store, and it is not
endorsed by the Hiddify team.

What the fork changes, change by change, is in **[CHANGES-FORK.md](CHANGES-FORK.md)** (in Russian). In short: no other
app can turn the tunnel on or off or import a profile silently; no local port without a password and no fixed control
ports on Android; Russian apps kept out of the tunnel by a built-in list, with the core dropping flows of apps the
tunnel does not cover; profiles, logs and keys in private storage, no backups; no update checks, analytics or other
requests to third parties; settings for Russia by default; AmneziaWG 3.1 profiles as ordinary nodes. It does **not**
make the tunnel invisible to other apps (see "Чего форк НЕ даёт" there). Android is the main platform; the Windows and
macOS builds have fewer of the changes (see the "Desktop" section of CHANGES-FORK.md).

## Downloads

[Releases](../../releases) of this repository, each built by GitHub Actions
([.github/workflows/sandpiper-release.yml](.github/workflows/sandpiper-release.yml)) from the tagged source of this
repository and of its core. Check a file against `SHA256SUMS.txt` of its release.

- **Android** — `Sandpiper-<version>-android-arm64-v8a.apk` for most phones (`-universal` for any). Signed by the
  release key; its certificate SHA-256 is given in the release notes.
- **Windows x64** — the installer `…-windows-x64-setup.exe` or the portable `…-windows-x64-portable.zip`. They are not
  code-signed: SmartScreen shows "Windows protected your PC"; after checking the SHA-256, choose *More info* → *Run
  anyway*.
- **macOS** — `…-macos-universal.dmg` (Apple Silicon and Intel), signed ad hoc, not notarized: drag the app to
  Applications, then Control-click it → *Open* → *Open*, or System Settings → Privacy & Security → *Open Anyway*.
- iOS: not built (it needs a paid Apple developer account).

## Source code

- This repository, branch `hardened`: the app (Flutter).
- The core it bundles: the submodule `hiddify-core`, [samutin97/sandpiper-engine](https://github.com/samutin97/sandpiper-engine)
  (a fork of [hiddify-core](https://github.com/hiddify/hiddify-core), branch `hardened`), with its own changed
  submodules: [sandpiper-engine-box](https://github.com/samutin97/sandpiper-engine-box) (hiddify-sing-box),
  [sandpiper-engine-links](https://github.com/samutin97/sandpiper-engine-links) (ray2sing),
  [sandpiper-engine-wire](https://github.com/samutin97/sandpiper-engine-wire) (amneziawg-go) and
  [sandpiper-engine-base](https://github.com/samutin97/sandpiper-engine-base) (sing). The other submodules are
  Hiddify's, unchanged.

Build: the release workflow above (Android, Windows x64, macOS; the core is built from the pinned submodule). Android
on a Windows PC: `VPN=<work folder> bash scripts/build-sandpiper-android.sh` (see its header; the core is checked by
SHA-256 by `scripts/fetch-core.sh`; a release build fails without the release key).

## License and credits

[Hiddify Extended GPL v3](LICENSE.md): GPL v3 with Hiddify's additional terms — source code published as a fork of
https://github.com/hiddify/hiddify-app, releases made by GitHub Actions, credit to Hiddify and its license, no
commercial use, no app-store listing under a name or interface like Hiddify's. The original README, with the
acknowledgements of the projects Hiddify is built on (sing-box, Xray, Clash and others), is at
https://github.com/hiddify/hiddify-app#readme.

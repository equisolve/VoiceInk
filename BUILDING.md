# Building VoiceInk

## Requirements

- macOS 15.0 or later
- Xcode with Command Line Tools
- Git

## Local Build

```bash
git clone https://github.com/Beingpax/VoiceInk.git
cd VoiceInk
make local
open ~/Downloads/VoiceInk.app
```

`make local` prepares `whisper.xcframework` in `~/VoiceInk-Dependencies`, builds Release in `.local-build`, and copies `VoiceInk.app` to `~/Downloads`.

It uses `LocalBuild.xcconfig`, `VoiceInk.local.entitlements`, and the `LOCAL_BUILD` Swift flag. Without an override, it uses the only available Apple Development identity or falls back to ad-hoc signing when none or multiple are found.

Choose an identity explicitly:

```bash
make local LOCAL_CODESIGN_IDENTITY="<SHA or name>"
```

Force ad-hoc signing:

```bash
make local LOCAL_CODESIGN_IDENTITY=-
```

Local builds do not include iCloud dictionary sync or automatic updates. Ad-hoc builds may require macOS permissions again after rebuilding.

## Other Commands

- `make check` — verify required tools
- `make whisper` — prepare `whisper.xcframework`
- `make build` — build the standard Debug configuration
- `make dev` — build and launch `VoiceInk Dev.app`
- `make run` — launch `~/Downloads/VoiceInk.app`, or the first app found in DerivedData
- `make release` — create the signed release package
- `make release-setup` — configure release notarization credentials
- `make equisolve-release` — build, sign, and notarize Equisolve's release; see [Equisolve release](#equisolve-release)
- `make equisolve-release-setup` — store Equisolve's notarization credentials
- `make clean` — remove `~/VoiceInk-Dependencies`
- `make help` — list all commands

## Build with Xcode

```bash
make setup
open VoiceInk.xcodeproj
```

Select the `VoiceInk` scheme. Run builds `VoiceInk Dev.app`; Archive uses Release. `LOCAL_BUILD` applies only through `make local`.

## Equisolve release

`make equisolve-release` builds the copy of VoiceInk that Equisolve deploys. It differs from `make release`:

- The bundle ID is `com.equisolve.VoiceInk`, so the app reads managed preferences from the `com.equisolve.VoiceInk` domain. The app keeps its data in `~/Library/Application Support/com.prakashjoshipax.VoiceInk/`, the same folder as other VoiceInk builds.
- It's signed with `Developer ID Application: Equisolve LLC (3MMFZ6XFFA)` with hardened runtime, then notarized and stapled.
- It uses the `LOCAL_BUILD` Swift flag, so it has no license check and no iCloud sync.
- It's signed with `release/equisolve/VoiceInk.entitlements`, which has no iCloud, push notification, or keychain group entitlements.
- Its `Info.plist` has no `SUFeedURL` or `SUPublicEDKey`, so VoiceInk never starts the Sparkle updater and never checks the upstream update feed. To update users, deploy a new build.
- The output is `VoiceInk.app` and a zip of it, in `~/Downloads/VoiceInk Equisolve Builds/VoiceInk-Equisolve-<timestamp>/`. The script doesn't build a DMG or an appcast.

The script builds the app without signing, changes the bundle ID and removes the feed in `Info.plist`, and then signs every library, framework, helper, and XPC service, and the app last. Before notarizing, it checks that each executable file has hardened runtime and Equisolve's team ID.

### Before your first release

You need the `Developer ID Application: Equisolve LLC (3MMFZ6XFFA)` certificate and its private key in your login keychain, and an Apple ID on Equisolve's Apple Developer team.

1. Create an app-specific password for that Apple ID, as described in [Sign in to apps with your Apple Account using app-specific passwords](https://support.apple.com/en-us/102654).
2. Store the notarization credentials in your keychain:

    ```bash
    make equisolve-release-setup
    ```

    The command asks for the Apple ID and then the app-specific password. It saves them as the notarytool profile `VoiceInk-Equisolve-Notarization` and checks them with Apple. The credentials stay in your keychain; never commit them.

### Build a release

1. Commit or discard your changes. The script refuses a working tree with uncommitted changes.
2. Run:

    ```bash
    make equisolve-release
    ```

    The script submits the app to Apple's notary service and waits for the result, which usually takes a few minutes. It then staples the ticket and checks the app with Gatekeeper.

3. Deploy the zip that the script prints.

To check the signing without notarizing, pass options through `EQUISOLVE_RELEASE_ARGS`:

```bash
make equisolve-release EQUISOLVE_RELEASE_ARGS="--skip-notarization --allow-dirty"
```

Pass `--identity -` to sign ad hoc on a Mac without the certificate. Neither kind of test build opens on other Macs. For all options, run `scripts/equisolve-release.sh --help`.

## Updating pinned dependencies

Third-party code and models are fixed to exact versions, so an update is always a reviewed change in a pull request. Each pin lives in one place:

| Dependency | Where the pin lives | How to update it |
| --- | --- | --- |
| whisper.cpp | `WHISPER_CPP_TAG` and `WHISPER_CPP_COMMIT` in `Makefile` | Set the new release tag and the commit it points to. Get the commit from the `^{}` line of `git ls-remote --tags https://github.com/ggml-org/whisper.cpp.git 'refs/tags/<tag>*'`; the other line is the tag object, which the build rejects. Run `make whisper`; it rebuilds whenever the commit changes and stops if the tag points anywhere else. The weekly upstream check reads `WHISPER_CPP_COMMIT` to decide which whisper.cpp and llama.cpp advisories are new. |
| Swift packages | Each package's requirement in `VoiceInk.xcodeproj/project.pbxproj` (`exactVersion` or `revision`), and `VoiceInk.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` | In Xcode, open **Package Dependencies**, change the package's rule to the new exact version or commit, and let Xcode update `Package.resolved`. Commit both files. `make build`, `make local`, `make release`, and `make equisolve-release` pass `-onlyUsePackageVersionsFromResolvedFile`, so they fail instead of resolving anything not recorded in `Package.resolved`, including transitive packages. |
| Parakeet V3 and Silero VAD models | `PinnedFluidAudioModels.parakeetV3` and `PinnedFluidAudioModels.vad` in `VoiceInk/Infrastructure/Providers/Transcription/FluidAudio/PinnedFluidAudioModels.swift` | Set `revision` to the new Hugging Face commit and replace `files` with the path, size, and SHA-256 of every file VoiceInk downloads at that commit. For large files, `https://huggingface.co/api/models/<repo>/tree/<revision>?recursive=1` lists the SHA-256 under `lfs.oid`; download and hash the small files. Downloading the model in the app then reports any file you missed, because files that aren't listed fail verification. If you also update FluidAudio, check that it still downloads the same file set. |
| VoiceInk Refine model | `VoiceInkRefineService.pinnedRevision` and `VoiceInkRefineModelDownloader.files` | Same as Parakeet: a new commit plus the size and SHA-256 of each file. |

Not pinned yet: the Whisper GGML models download from the `main` branch of `ggerganov/whisper.cpp` on Hugging Face (`VoiceInk/Features/ModelLibrary/Models/TranscriptionModel.swift`), and the FluidAudio models other than Parakeet V3 and Silero VAD (Parakeet V2, Parakeet Ultra, Parakeet Unified, and Nemotron) use FluidAudio's default revision without a VoiceInk hash check.

## Troubleshooting

- Run `make check` to verify the required tools.
- Run `make whisper` if the framework is missing.
- If several Apple Development identities exist, set `LOCAL_CODESIGN_IDENTITY` explicitly.
- For additional help, open a [GitHub issue](https://github.com/Beingpax/VoiceInk/issues).

## Keeping VoiceInk updated

This fork follows upstream [Beingpax/VoiceInk](https://github.com/Beingpax/VoiceInk) releases on a fixed schedule:

- **Monthly update.** Once a month, one pull request merges the latest upstream VoiceInk release, bumps the pinned dependencies, and sets `UPSTREAM_VERSION` to the merged release's tag. After review, the release is built, signed, notarized, and published in Self Service.
- **Security fixes.** A security fix in upstream VoiceInk or in a dependency doesn't wait for the monthly update. It ships as soon as it's built and tested.
- **Weekly check.** The [Upstream update check](.github/workflows/upstream-update-check.yml) workflow runs every Monday and on demand from the **Actions** tab. It runs `scripts/check-upstream-updates.sh`, which compares upstream releases against the tag in `UPSTREAM_VERSION`. It also lists security advisories for upstream VoiceInk published since that release, and advisories for whisper.cpp and llama.cpp (where advisories for the ggml library that whisper.cpp bundles are published) published since the whisper.cpp commit that `WHISPER_CPP_COMMIT` in the `Makefile` pins. If the `Makefile` has no pin, it lists every whisper.cpp and llama.cpp advisory. When anything is new, it opens one issue titled "Upstream VoiceInk updates and security advisories" and labeled `upstream-update`, or updates the open one and comments when the list changes. When nothing is new, it closes the issue.
- **Swift package advisories.** Dependabot alerts read the Swift packages in `VoiceInk.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`. `.github/dependabot.yml` turns off routine version update pull requests and leaves Dependabot security updates on, so Dependabot tries to open a pull request for a package with an alert. GitHub's documentation doesn't cover security update pull requests for an Xcode project with no `Package.swift`, which is how VoiceInk is set up, so treat an alert as the signal and update the package yourself if no pull request appears.

`UPSTREAM_VERSION` records the upstream base in one file because Git history can't show it reliably: if the monthly update pull request is squash-merged, the upstream release commit isn't in this repository's history, so `git describe` reports an older tag.

To preview the issue without changing anything, run:

```bash
scripts/check-upstream-updates.sh --dry-run
```

The script needs `gh` (signed in) and `jq`. To compare against a different release, set `UPSTREAM_BASE`, for example `UPSTREAM_BASE=v2.13`.

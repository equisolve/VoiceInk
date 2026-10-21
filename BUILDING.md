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
- `make clean` — remove `~/VoiceInk-Dependencies`
- `make help` — list all commands

## Build with Xcode

```bash
make setup
open VoiceInk.xcodeproj
```

Select the `VoiceInk` scheme. Run builds `VoiceInk Dev.app`; Archive uses Release. `LOCAL_BUILD` applies only through `make local`.

## Updating pinned dependencies

Third-party code and models are fixed to exact versions, so an update is always a reviewed change in a pull request. Each pin lives in one place:

| Dependency | Where the pin lives | How to update it |
| --- | --- | --- |
| whisper.cpp | `WHISPER_CPP_TAG` and `WHISPER_CPP_COMMIT` in `Makefile` | Set the new release tag and the commit it points to. Get the commit from the `^{}` line of `git ls-remote --tags https://github.com/ggml-org/whisper.cpp.git 'refs/tags/<tag>*'`; the other line is the tag object, which the build rejects. Run `make whisper`; it rebuilds whenever the commit changes and stops if the tag points anywhere else. |
| Swift packages | Each package's requirement in `VoiceInk.xcodeproj/project.pbxproj` (`exactVersion` or `revision`), and `VoiceInk.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` | In Xcode, open **Package Dependencies**, change the package's rule to the new exact version or commit, and let Xcode update `Package.resolved`. Commit both files. `make build`, `make local`, and `make release` pass `-onlyUsePackageVersionsFromResolvedFile`, so they fail instead of resolving anything not recorded in `Package.resolved`, including transitive packages. |
| Parakeet V3 and Silero VAD models | `PinnedFluidAudioModels.parakeetV3` and `PinnedFluidAudioModels.vad` in `VoiceInk/Infrastructure/Providers/Transcription/FluidAudio/PinnedFluidAudioModels.swift` | Set `revision` to the new Hugging Face commit and replace `files` with the path, size, and SHA-256 of every file VoiceInk downloads at that commit. For large files, `https://huggingface.co/api/models/<repo>/tree/<revision>?recursive=1` lists the SHA-256 under `lfs.oid`; download and hash the small files. Downloading the model in the app then reports any file you missed, because files that aren't listed fail verification. If you also update FluidAudio, check that it still downloads the same file set. |
| VoiceInk Refine model | `VoiceInkRefineService.pinnedRevision` and `VoiceInkRefineModelDownloader.files` | Same as Parakeet: a new commit plus the size and SHA-256 of each file. |

Not pinned yet: the Whisper GGML models download from the `main` branch of `ggerganov/whisper.cpp` on Hugging Face (`VoiceInk/Features/ModelLibrary/Models/TranscriptionModel.swift`), and the FluidAudio models other than Parakeet V3 and Silero VAD (Parakeet V2, Parakeet Ultra, Parakeet Unified, and Nemotron) use FluidAudio's default revision without a VoiceInk hash check.

## Troubleshooting

- Run `make check` to verify the required tools.
- Run `make whisper` if the framework is missing.
- If several Apple Development identities exist, set `LOCAL_CODESIGN_IDENTITY` explicitly.
- For additional help, open a [GitHub issue](https://github.com/Beingpax/VoiceInk/issues).

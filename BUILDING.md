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

## Troubleshooting

- Run `make check` to verify the required tools.
- Run `make whisper` if the framework is missing.
- If several Apple Development identities exist, set `LOCAL_CODESIGN_IDENTITY` explicitly.
- For additional help, open a [GitHub issue](https://github.com/Beingpax/VoiceInk/issues).

## Keeping VoiceInk updated

This fork follows upstream [Beingpax/VoiceInk](https://github.com/Beingpax/VoiceInk) releases on a fixed schedule:

- **Monthly update.** Once a month, one pull request merges the latest upstream VoiceInk release, bumps the pinned dependencies, and sets `UPSTREAM_VERSION` to the merged release's tag. After review, the release is built, signed, notarized, and published in Self Service.
- **Security fixes.** A security fix in upstream VoiceInk or in a dependency doesn't wait for the monthly update. It ships as soon as it's built and tested.
- **Weekly check.** The [Upstream update check](.github/workflows/upstream-update-check.yml) workflow runs every Monday and on demand from the **Actions** tab. It runs `scripts/check-upstream-updates.sh`, which compares upstream releases against the tag in `UPSTREAM_VERSION` and lists security advisories published since that release for upstream VoiceInk, whisper.cpp, and llama.cpp (where advisories for the ggml library that whisper.cpp bundles are published). When anything is new, it opens one issue labeled `upstream-update`, or updates the open one and comments when the list changes. When nothing is new, it closes the issue.
- **Swift package advisories.** With **Dependabot alerts** and **Dependabot security updates** turned on under **Settings > Advanced Security**, Dependabot alerts cover the Swift packages in `Package.resolved`. `.github/dependabot.yml` turns off routine version update pull requests, so Dependabot opens a pull request only to fix a package with an alert.

`UPSTREAM_VERSION` records the upstream base in one file because Git history can't show it reliably: if the monthly update pull request is squash-merged, the upstream release commit isn't in this repository's history, so `git describe` reports an older tag.

To preview the issue without changing anything, run:

```bash
scripts/check-upstream-updates.sh --dry-run
```

The script needs `gh` (signed in) and `jq`. To compare against a different release, set `UPSTREAM_BASE`, for example `UPSTREAM_BASE=v2.13`.

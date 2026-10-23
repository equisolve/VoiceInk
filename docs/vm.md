# Run the app in a macOS VM

Use a headless macOS virtual machine (VM) whenever you need the real VoiceInk Dev app running: screenshots, manual checks, onboarding flows, or permission prompts. The VM runs with no window on the host, so nothing appears on your display and the copy of VoiceInk you use every day is untouched.

You build the app on the host with `xcodebuild`, copy the built `.app` into the VM, and drive it from the host with the scripts in `scripts/vm/`.

Never launch VoiceInk or VoiceInk Dev on the host for these checks, and never run `tart run` without `--no-graphics`.

## How it works

- [Tart](https://tart.run) runs the VM with Apple's Virtualization framework. `scripts/vm/vm-up.sh` starts it with `--no-graphics --vnc-experimental`. With `--no-graphics`, tart opens no window and only prints the address of the framework's built-in VNC server, which listens on `127.0.0.1` with a random password. The scripts use that address only while the `tart run` process that `vm-up.sh` started is still running. If the VM was started some other way, stop it with `vm-down.sh` and start it again with `vm-up.sh`.
- The scripts copy the app in and launch it over SSH.
- `scripts/vm/vm-vnc.swift` is a small command-line client for that VNC server. It reads the VM's screen into a PNG and sends mouse clicks and keystrokes through the VM's virtual mouse and keyboard. It opens no window. The scripts compile it to `~/.tart/vm-vnc` on first use.

`screencapture` inside the VM can't take the screenshots. It needs the Screen Recording permission, and macOS grants that only through a click in the VM or with System Integrity Protection turned off. Reading the framebuffer from the host needs neither.

## One-time setup

1. Install tart and `sshpass`. The `cirruslabs/cli/tart` Homebrew formula fails to install on current Homebrew, so install tart from its GitHub release:

   ```sh
   brew install sshpass
   tart_dl="$(mktemp -d)"
   gh release download -R cirruslabs/tart -p 'tart*' -D "$tart_dl"
   cd "$tart_dl"
   shasum -a 256 -c tart_*_checksums.txt --ignore-missing
   tar -xzf tart.tar.gz
   mkdir -p ~/.local/lib
   mv tart.app ~/.local/lib/
   ln -sf ~/.local/lib/tart.app/Contents/MacOS/tart /opt/homebrew/bin/tart
   ```

   If `brew install cirruslabs/cli/tart` works for you, use that instead.

2. Clone the Cirrus Labs vanilla image that matches the host's macOS major version into a VM named `voiceink`. The vanilla image has no Xcode, so it stays small. For macOS 27, the image is `macos-golden-gate-vanilla`; for macOS 26, it's `macos-tahoe-vanilla`. The [Cirrus Labs packages page](https://github.com/orgs/cirruslabs/packages?q=vanilla) lists the others.

   ```sh
   tart clone ghcr.io/cirruslabs/macos-golden-gate-vanilla:latest voiceink
   tart set voiceink --cpu 4 --memory 8192
   tart prune --entries caches --older-than 0
   ```

   The download is about 31 GB compressed. The VM uses about 35 GB in `~/.tart`. Pruning the cache removes the downloaded copy; you need it again only to clone another VM.

3. Start the VM once to create its SSH key:

   ```sh
   scripts/vm/vm-up.sh
   ```

   The image signs in to the desktop as `admin` (password `admin`) at boot. `vm-up.sh` creates `~/.tart/voiceink_ed25519` and adds it to the VM's `authorized_keys` with that password. Every later SSH call uses the key.

Tart is free for personal workstations. See [Tart licensing](https://tart.run/licensing/).

## Scripts

The scripts are Bash and run with the `/bin/bash` that ships with macOS. Every script prints what it did and exits non-zero on failure. Set `VOICEINK_VM` to use a VM with a name other than `voiceink`.

| Script | What it does |
| --- | --- |
| `scripts/vm/vm-up.sh` | Starts the VM with no window, if it isn't running, and waits for SSH. |
| `scripts/vm/vm-install-app.sh <path-to-.app>` | Quits the app in the VM, then copies the bundle into the VM's `/Applications`, replacing any old copy. |
| `scripts/vm/vm-run.sh` | Opens `/Applications/VoiceInk Dev.app` in the VM's desktop session and waits for its process. |
| `scripts/vm/vm-screenshot.sh <out.png>` | Saves the VM's whole screen as a PNG on the host. |
| `scripts/vm/vm-input.sh click <x> <y>` | Clicks at a point. Use pixel coordinates from a `vm-screenshot.sh` PNG. |
| `scripts/vm/vm-input.sh type <text>` | Types text. |
| `scripts/vm/vm-input.sh key <combo>` | Presses a key or combination, such as `return`, `escape`, `cmd+q`, or `cmd+comma`. |
| `scripts/vm/vm-down.sh` | Stops the VM. |

`vm-run.sh` launches the app with `launchctl asuser` so it runs in the logged-in desktop session. A plain `open` over SSH runs outside that session.

## Build and check the app

1. Build VoiceInk Dev on the host. This is the Debug configuration with the ad hoc signing settings that `make local` uses, so it needs no Apple Developer certificate. Set `VOICEINK_BUILD_DIR` to any directory outside the repo; the build output is about 4 GB. Run this from the repo root:

   ```sh
   VOICEINK_BUILD_DIR="${VOICEINK_BUILD_DIR:-$HOME/voiceink-vm-build}"
   xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug \
     -derivedDataPath "$VOICEINK_BUILD_DIR" \
     -xcconfig LocalBuild.xcconfig \
     CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM="" \
     CODE_SIGN_ENTITLEMENTS="$PWD/VoiceInk/VoiceInk.local.entitlements" \
     -onlyUsePackageVersionsFromResolvedFile -skipPackagePluginValidation -skipMacroValidation \
     build
   ```

   `make build` fails with ad hoc signing because the Debug entitlements need a development certificate. Run `make whisper` first if `~/VoiceInk-Dependencies` doesn't have the whisper framework yet.

2. Start the VM, install the app, and run it:

   ```sh
   scripts/vm/vm-up.sh
   scripts/vm/vm-install-app.sh "$VOICEINK_BUILD_DIR/Build/Products/Debug/VoiceInk Dev.app"
   scripts/vm/vm-run.sh
   ```

3. Wait a few seconds for the window, then take a screenshot and look at it:

   ```sh
   scripts/vm/vm-screenshot.sh /tmp/voiceink.png
   ```

4. Stop the VM when you're done:

   ```sh
   scripts/vm/vm-down.sh
   ```

## Reach a specific screen

The app isn't sandboxed, so it reads its settings from the `com.prakashjoshipax.VoiceInk.dev` defaults domain in the VM. Write settings in the VM over SSH while the app is quit, then launch it. Every `defaults` command in this section runs in the VM, never on the host, where it would change your own copy of the app.

To skip onboarding and open the main window, and to keep the What's New sheet from covering it:

```sh
ssh -i ~/.tart/voiceink_ed25519 -o IdentitiesOnly=yes -o IdentityAgent=none admin@"$(tart ip voiceink)" \
  'pkill -x "VoiceInk Dev"; defaults write com.prakashjoshipax.VoiceInk.dev hasCompletedOnboardingV2 -bool true; defaults write com.prakashjoshipax.VoiceInk.dev VoiceInkDismissedChangeLogItemIDs -array dictionary-auto-learn'
scripts/vm/vm-run.sh
```

Replace `dictionary-auto-learn` with the `id` of `ChangeLogCatalog.latest` in `VoiceInk/App/ChangeLog/ChangeLogManager.swift`.

To return to onboarding, delete the domain in the VM:

```sh
ssh -i ~/.tart/voiceink_ed25519 -o IdentitiesOnly=yes -o IdentityAgent=none admin@"$(tart ip voiceink)" \
  'pkill -x "VoiceInk Dev"; defaults delete com.prakashjoshipax.VoiceInk.dev'
scripts/vm/vm-run.sh
```

The main window always opens on Dashboard, and the app has no URL scheme or command-line option for choosing a page. To open another page, take a screenshot, find the sidebar item, and click it:

```sh
scripts/vm/vm-screenshot.sh /tmp/before.png
scripts/vm/vm-input.sh click 222 428    # History, in a 2048 x 1536 screenshot
scripts/vm/vm-screenshot.sh /tmp/history.png
```

### Grant permissions

Permission prompts inside the VM accept clicks from `vm-input.sh`, because the clicks come from the VM's virtual mouse. To grant the microphone, click **Allow** on the onboarding screen, take a screenshot, and then click **Allow** in the macOS prompt. The VM remembers the grant for the installed app until you replace it with a differently signed build.

You can't grant permissions over SSH. The permission database in the VM is protected by System Integrity Protection, which stays on.

## Watch the host for windows

To prove that nothing appeared on the host, poll the host's window list while you work and record any window owned by tart, VoiceInk Dev, or the Virtualization framework. Save this as `winpoll.swift` outside the repo, compile it with `swiftc -O winpoll.swift -o winpoll`, and run `./winpoll > winpoll.log` in another terminal:

```swift
import CoreGraphics
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
let patterns = ["tart", "voiceink dev", "virtualization"]
var polls = 0
while true {
    polls += 1
    let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    for w in windows {
        let owner = (w[kCGWindowOwnerName as String] as? String) ?? ""
        if patterns.contains(where: { owner.lowercased().contains($0) }) {
            print("\(Date()) window owner=\(owner) name=\(w[kCGWindowName as String] ?? "")")
        }
    }
    if polls % 120 == 0 { print("\(Date()) polls=\(polls)") }
    usleep(500_000)
}
```

## Known limits

- **No microphone.** Nothing speaks into the VM, so recording and live transcription can't be tested. Granting the Microphone permission works.
- **No iCloud.** The VM isn't signed in to an Apple Account, and the local build turns off iCloud dictionary sync.
- **Two macOS VMs at a time.** macOS lets a host run at most two macOS VMs at once, and other agents or tools on the same Mac count toward that limit. If `vm-up.sh` fails to start the VM, run `tart list` to look for other running VMs.
- **Small screen.** The VM's screen is 1024 x 768 points, shown at 2048 x 1536 pixels in screenshots, so the onboarding window extends behind the Dock.
- **Screenshot after boot.** The first screenshot after the VM starts can be black. Take it again after a few seconds.
- **Ad hoc signing.** Each rebuild has a new signature, so macOS in the VM may ask for permissions again after you install a new build.

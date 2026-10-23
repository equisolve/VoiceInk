# Agent rules for VoiceInk

These rules apply to every coding agent that works in this repository.

## Never launch VoiceInk on the host Mac

Never launch VoiceInk or VoiceInk Dev on the developer's Mac, for screenshots or for any other reason. The app opens windows, adds a menu bar item, takes focus, and registers global shortcuts, which interrupts the person using the Mac.

This rule covers every way to start the app, including these:

- `open` on any `VoiceInk.app` or `VoiceInk Dev.app` bundle.
- Running the app's executable directly.
- `make run` and `make dev`, which open the built app.
- Xcode's Run action.
- The `VoiceInkUITests` target, which launches the full app. The `VoiceInk` scheme skips it.

## Run the real app in the Tart VM

Any run of the real app, and every PR screenshot, happens in the headless Tart macOS VM described in [docs/vm.md](docs/vm.md), never on the host.

## Build and test

Build and test with the Makefile:

- `make build` builds the app.
- `make test` builds the app and runs the `VoiceInkTests` unit tests. It signs ad hoc, so it works on a Mac without the team's development certificate.

`make test` and `xcodebuild test -scheme VoiceInk` are safe to run on the host. The scheme tests the Debug build, whose test host is VoiceInk Dev. When VoiceInk Dev starts under XCTest, it sets the activation policy to `.prohibited` and runs a bare `NSApplication`. It shows no window, menu bar item, or Dock icon, and it doesn't register shortcuts, start audio, or show onboarding. For details, see `VoiceInkLauncher` in `VoiceInk/App/VoiceInk.swift`.

A Release build doesn't detect a test run, so testing the Release configuration launches the full app. Don't pass `-configuration Release` to `xcodebuild test`.

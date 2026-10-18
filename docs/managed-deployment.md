# Managed deployment

This page is for administrators who deploy VoiceInk with a mobile device management (MDM) service, such as Jamf Pro. It describes the preference key that turns off cloud services and gives a sample configuration profile.

## Turn off cloud services

Set the Boolean key `DisableCloudServices` to `true` in the `com.prakashjoshipax.VoiceInk` preference domain. When the key is `false` or absent, VoiceInk behaves exactly as it does without the key.

When the value comes from a configuration profile, users can't change it, and the app labels each hidden or turned-off option with **Managed by your organization**. When the value is set locally with `defaults write`, the app shows **Cloud services are turned off** instead.

VoiceInk reads the key each time it needs it, so a new profile takes effect without restarting the app. Some screens refresh the next time they open.

### What the key blocks

When `DisableCloudServices` is `true`:

- **Cloud transcription.** Every non-local transcription provider is hidden from model pickers and refused before any audio is read or sent. This includes Groq, ElevenLabs, Deepgram, Mistral, Gemini, Soniox, Speechmatics, AssemblyAI, xAI, Cartesia, OpenRouter, custom transcription endpoints, and any cloud provider added in a later release. Only Whisper, Parakeet, transcribe.cpp, and Apple Speech models are available.
- **Modes that use a cloud transcription model.** VoiceInk uses the default transcription model if it's local and downloaded, otherwise the first downloaded local model. If no local model is downloaded, recording stops with an error that tells the user to choose a local model. Audio is never sent to a cloud service.
- **Cloud AI enhancement.** Only VoiceInk Refine, Ollama, and custom OpenAI-compatible models are available, and Ollama and custom models only when their server URL host is `localhost`, `127.0.0.1`, or `::1`. VoiceInk refuses an Ollama server on another computer, including model listing and connection checks. The CLI provider is turned off, because the command it runs can reach cloud services. All other providers are hidden and refused before any text is sent.
- **Modes that use a blocked AI provider.** VoiceInk pastes the transcript without AI enhancement and shows a short notice with the reason.
- **API key entry.** The **Cloud** tab in **AI Models** shows a notice instead of the provider list, and onboarding skips the cloud provider steps. Keys already saved in the Keychain are ignored, not deleted, so they work again if the key is removed.
- **Auto-Learn Dictionary.** Auto-Learn requests go through the same check, so they can use only the allowed AI providers.
- **Model catalog refreshes.** VoiceInk doesn't download the OpenRouter model lists.

### What the key doesn't block

The key covers transcription and AI enhancement. These network connections aren't affected:

- Downloads of local models (Whisper, Parakeet, transcribe.cpp, and VoiceInk Refine).
- Update checks through Sparkle. To turn off automatic checks, set `VoiceInkChecksForUpdatesOnLaunch` to `false`.
- In-app announcements. To turn them off, set `enableAnnouncements` to `false`.
- License activation and validation.

## Other useful keys

All of these keys are in the `com.prakashjoshipax.VoiceInk` domain.

| Key | Type | Effect |
| --- | --- | --- |
| `DisableCloudServices` | Boolean | `true` turns off cloud transcription and cloud AI enhancement, as described on this page. |
| `IsAutoLearnDictionaryEnabled` | Boolean | `false` turns off Auto-Learn Dictionary. |
| `enableAnnouncements` | Boolean | `false` turns off in-app announcements. |
| `VoiceInkChecksForUpdatesOnLaunch` | Boolean | `false` turns off automatic update checks. |
| `IsTranscriptionCleanupEnabled` | Boolean | `true` deletes transcripts and recordings after the retention period. |
| `TranscriptionRetentionMinutes` | Integer | How long to keep transcripts and recordings, in minutes, when cleanup is on. For example, `10080` is seven days. |

## Sample configuration profile

This profile sets all of the keys in the previous table. Upload it to your MDM service as a custom configuration profile, or paste the inner dictionary under `mcx_preference_settings` into a custom settings payload for the `com.prakashjoshipax.VoiceInk` domain. Replace the `PayloadUUID` values with your own (run `uuidgen`), and change `PayloadIdentifier` and `PayloadOrganization` to match your organization.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>PayloadContent</key>
    <array>
        <dict>
            <key>PayloadType</key>
            <string>com.apple.ManagedClient.preferences</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
            <key>PayloadIdentifier</key>
            <string>com.example.voiceink.preferences</string>
            <key>PayloadUUID</key>
            <string>D0922053-38EE-440C-B4EA-17E8494BA305</string>
            <key>PayloadDisplayName</key>
            <string>VoiceInk settings</string>
            <key>PayloadContent</key>
            <dict>
                <key>com.prakashjoshipax.VoiceInk</key>
                <dict>
                    <key>Forced</key>
                    <array>
                        <dict>
                            <key>mcx_preference_settings</key>
                            <dict>
                                <key>DisableCloudServices</key>
                                <true/>
                                <key>IsAutoLearnDictionaryEnabled</key>
                                <false/>
                                <key>enableAnnouncements</key>
                                <false/>
                                <key>VoiceInkChecksForUpdatesOnLaunch</key>
                                <false/>
                                <key>IsTranscriptionCleanupEnabled</key>
                                <true/>
                                <key>TranscriptionRetentionMinutes</key>
                                <integer>10080</integer>
                            </dict>
                        </dict>
                    </array>
                </dict>
            </dict>
        </dict>
    </array>
    <key>PayloadDisplayName</key>
    <string>VoiceInk managed settings</string>
    <key>PayloadIdentifier</key>
    <string>com.example.voiceink</string>
    <key>PayloadOrganization</key>
    <string>Example Organization</string>
    <key>PayloadScope</key>
    <string>System</string>
    <key>PayloadType</key>
    <string>Configuration</string>
    <key>PayloadUUID</key>
    <string>24F5F70C-9B39-4C17-BCD9-D11A67B8DA6A</string>
    <key>PayloadVersion</key>
    <integer>1</integer>
</dict>
</plist>
```

To check the result on a Mac that has the profile, run:

```sh
defaults read com.prakashjoshipax.VoiceInk DisableCloudServices
```

The command prints `1` when cloud services are off.

## Deny Screen Recording

VoiceInk asks for Screen Recording permission to read on-screen text for context-aware enhancement. To deny it, deploy a Privacy Preferences Policy Control (PPPC) profile with a `ScreenCapture` entry for VoiceInk set to deny. The entry needs the code requirement of the signed build you deploy. To get it, run this command against the installed app:

```sh
codesign -dr - /Applications/VoiceInk.app
```

Rebuilding or re-signing the app changes the code requirement, so update the PPPC profile whenever you deploy a build signed with a different identity.

## Test the key without a profile

To try the behavior on one Mac without MDM, set the key locally, then relaunch VoiceInk:

```sh
defaults write com.prakashjoshipax.VoiceInk DisableCloudServices -bool true
```

To go back to the default behavior, delete the key:

```sh
defaults delete com.prakashjoshipax.VoiceInk DisableCloudServices
```

A value set this way isn't managed, so users can change it the same way.

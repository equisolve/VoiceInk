# Managed deployment

This page is for administrators who deploy VoiceInk with a mobile device management (MDM) service, such as Jamf Pro. It describes the preference keys that turn off cloud services, set up an organization AI endpoint, and set default models, and gives a sample configuration profile.

## Turn off cloud services

Set the Boolean key `DisableCloudServices` to `true` in the `com.prakashjoshipax.VoiceInk` preference domain. When the key is `false` or absent, VoiceInk behaves exactly as it does without the key.

When the value comes from a configuration profile, users can't change it, and the app labels each hidden or turned-off option with **Managed by your organization**. When the value is set locally with `defaults write`, the app shows **Cloud services are turned off** instead.

VoiceInk applies a change to the key while it runs, so you don't need to restart the app. When cloud services turn off, VoiceInk moves off a cloud transcription model and open screens update. When they turn back on, VoiceInk returns to the model the user chose before. A streaming transcription that started before the change can finish.

### What the key blocks

When `DisableCloudServices` is `true`:

- **Cloud transcription.** Every non-local transcription provider is hidden from model pickers and refused before any audio is read or sent. This includes Groq, ElevenLabs, Deepgram, Mistral, Gemini, Soniox, Speechmatics, AssemblyAI, xAI, Cartesia, OpenRouter, custom transcription endpoints, and any cloud provider added in a later release. Only Whisper, Parakeet, transcribe.cpp, and Apple Speech models are available.
- **Modes that use a cloud transcription model.** VoiceInk uses the default transcription model if it's local and downloaded, otherwise the first downloaded local model. If no local model is downloaded, recording stops with an error that tells the user to choose a local model. Audio is never sent to a cloud service.
- **Cloud AI enhancement.** Only VoiceInk Refine, Ollama, custom OpenAI-compatible models, and the [organization AI endpoint](#provide-an-organization-ai-endpoint) are available. Ollama and custom models are allowed only when their server URL host is `localhost`, `127.0.0.1`, or `::1`, or when the URL is inside the organization AI endpoint. VoiceInk refuses an Ollama server on another computer, including model listing and connection checks. The CLI provider is turned off, because the command it runs can reach cloud services. All other providers are hidden and refused before any text is sent.
- **Modes that use a blocked AI provider.** VoiceInk uses the organization AI endpoint when one is set up. Otherwise, it pastes the transcript without AI enhancement and shows a short notice with the reason.
- **API key entry.** The **Cloud** tab in **AI Models** shows a notice instead of the provider list, and onboarding skips the cloud provider steps. Keys already saved in the Keychain are ignored, not deleted, so they work again if the key is removed.
- **Auto-Learn Dictionary.** Auto-Learn requests go through the same check, so they can use only the allowed AI providers.
- **Model catalog refreshes.** VoiceInk doesn't download the OpenRouter model lists.

VoiceInk fully trusts an Ollama or custom endpoint on `localhost`, `127.0.0.1`, or `::1`, including any redirect or forwarding that server does. For example, a local proxy such as LiteLLM can accept a request on `localhost` and send it to a cloud service, and VoiceInk follows a redirect from a local server to another host. Allow only local servers that you control.

### What the key doesn't block

The key covers transcription and AI enhancement. These network connections aren't affected:

- Downloads of local models (Whisper, Parakeet, transcribe.cpp, and VoiceInk Refine).
- Update checks through Sparkle. To turn off automatic checks, set `VoiceInkChecksForUpdatesOnLaunch` to `false`.
- In-app announcements. To turn them off, set `enableAnnouncements` to `false`.
- License activation and validation.

## Provide an organization AI endpoint

To give users AI enhancement through a service your organization runs, set these keys in the `com.prakashjoshipax.VoiceInk` domain. The endpoint must accept OpenAI-compatible chat completion requests.

| Key | Type | Value |
| --- | --- | --- |
| `ManagedAIEndpointURL` | String | The base URL of the API, such as `https://ai.example.com/v1`. VoiceInk sends requests to `chat/completions` under it. A URL that already ends in `/chat/completions` is used as is. |
| `ManagedAIModel` | String | The model name to send with each request. |
| `ManagedAIToken` | String | The token to send in an `Authorization: Bearer` header. Optional. |
| `ManagedAIProviderName` | String | The provider name users see. Optional. The default is **Organization AI**. |

When `ManagedAIEndpointURL` and `ManagedAIModel` are both set:

- The **Cloud** tab in **AI Models** shows the provider, model, and endpoint as read-only, labeled **Managed by your organization** when the values come from a configuration profile. The token itself isn't shown.
- The provider is first in the AI provider lists and becomes the selected provider when it first appears or when its URL or model changes. Users can pick another allowed provider afterward.
- VoiceInk reads the token for each request. It doesn't copy the token to the Keychain, logs, or history. Without a token, VoiceInk sends no `Authorization` header.
- Changes to these keys apply while the app runs.
- To make the provider the default for enhancement, set `DefaultEnhancementProvider` to `Managed`, as described in [Set default models](#set-default-models).

Each request is a `POST` to `chat/completions` with the default cleanup prompt and the custom vocabulary as the system message, and the transcript as the user message, the same as other OpenAI-compatible providers. The body has only `model`, `messages`, and `stream` (`false`). VoiceInk doesn't send `temperature` or other sampling settings, because some models reject them: Claude Haiku 5.5 on Amazon Bedrock rejects a request that sets `temperature`. Set sampling options on the proxy if you need them.

VoiceInk follows a redirect from the endpoint only when it keeps the endpoint's scheme, host, and port. It refuses any other redirect and reports an error, so the token isn't sent to another server. This applies whether or not `DisableCloudServices` is set.

### Use LiteLLM as the endpoint

A [LiteLLM proxy](https://docs.litellm.ai/docs/simple_proxy) works as the endpoint. Set `ManagedAIEndpointURL` to the proxy's URL with `/v1`, such as `https://ai.example.com/v1`, `ManagedAIModel` to a `model_name` from the proxy's `config.yaml`, and `ManagedAIToken` to a [virtual key](https://docs.litellm.ai/docs/proxy/virtual_keys) limited to that model. For example:

```yaml
model_list:
  - model_name: voiceink-cleanup
    litellm_params:
      model: bedrock/us.anthropic.claude-haiku-5-5
      aws_region_name: us-east-1
      drop_params: true
```

`drop_params` isn't needed for VoiceInk's requests, but it keeps other clients of the same model from failing on parameters the model doesn't support.

When `DisableCloudServices` is also `true`:

- VoiceInk sends text only to loopback hosts and to URLs inside the endpoint: the same scheme, host, and port, with a path that starts with the endpoint's path. With `https://ai.example.com/v1`, VoiceInk allows `https://ai.example.com/v1/chat/completions`, but not `https://ai.example.com/v2`, `https://ai.example.com:8443/v1`, or `https://ai.example.com.example.net/v1`.
- The endpoint must use `https` unless its host is `localhost`, `127.0.0.1`, or `::1`. VoiceInk refuses an `http` endpoint on another host, so the token is never sent unencrypted.
- Modes set to a blocked provider use the organization provider.
- Transcription is unchanged. Only local transcription models are available.

When `DisableCloudServices` is `false` or absent, the organization provider is added to the providers users already have, and every other provider stays available.

**Warning:** Any user or process on the Mac can read a value delivered in a configuration profile, including `ManagedAIToken`. Use a token that works only with your proxy and that you can revoke, never an API key for an AI provider.

## Other useful keys

All of these keys are in the `com.prakashjoshipax.VoiceInk` domain.

| Key | Type | Effect |
| --- | --- | --- |
| `DisableCloudServices` | Boolean | `true` turns off cloud transcription and cloud AI enhancement, as described on this page. |
| `ManagedAIEndpointURL`, `ManagedAIModel`, `ManagedAIToken`, `ManagedAIProviderName` | String | Set up an organization AI endpoint, as described in [Provide an organization AI endpoint](#provide-an-organization-ai-endpoint). |
| `IsAutoLearnDictionaryEnabled` | Boolean | `false` turns off Auto-Learn Dictionary. |
| `enableAnnouncements` | Boolean | `false` turns off in-app announcements. |
| `VoiceInkChecksForUpdatesOnLaunch` | Boolean | `false` turns off automatic update checks. |
| `IsTranscriptionCleanupEnabled` | Boolean | `true` deletes transcripts and recordings after the retention period. |
| `TranscriptionRetentionMinutes` | Integer | How long to keep transcripts and recordings, in minutes, when cleanup is on. For example, `10080` is seven days. |

## Sample configuration profile

This profile sets all of the keys in the previous table and the [default models](#set-default-models): Parakeet for transcription and the organization AI endpoint for enhancement, with VoiceInk Refine downloaded as the fallback. Auto-Learn Dictionary stays off. Replace the `ManagedAI` values with your endpoint, model, and token. If you don't run an AI endpoint, remove those keys and set `DefaultEnhancementProvider` to `VoiceInk Refine`. Upload it to your MDM service as a custom configuration profile, or paste the inner dictionary under `mcx_preference_settings` into a custom settings payload for the `com.prakashjoshipax.VoiceInk` domain. Replace the `PayloadUUID` values with your own (run `uuidgen`), and change `PayloadIdentifier` and `PayloadOrganization` to match your organization.

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
                                <key>ManagedAIEndpointURL</key>
                                <string>https://ai.example.com/v1</string>
                                <key>ManagedAIModel</key>
                                <string>voiceink-cleanup</string>
                                <key>ManagedAIToken</key>
                                <string>PROXY_ONLY_TOKEN</string>
                                <key>ManagedAIProviderName</key>
                                <string>Example AI</string>
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
                                <key>DefaultTranscriptionModel</key>
                                <string>parakeet-tdt-0.6b-v3</string>
                                <key>DefaultEnhancementProvider</key>
                                <string>Managed</string>
                                <key>DefaultEnhancementEnabled</key>
                                <true/>
                                <key>AutoDownloadModels</key>
                                <array>
                                    <string>parakeet-tdt-0.6b-v3</string>
                                    <string>VoiceInk Refine V1</string>
                                </array>
                                <key>ManagedDefaultsVersion</key>
                                <integer>1</integer>
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

## Set default models

These keys set starting choices that users can change later. They are separate from the keys in the previous table: a profile forces every key it sets, so VoiceInk reads these keys and copies their values into its own settings, which stay editable.

| Key | Type | Effect |
| --- | --- | --- |
| `DefaultTranscriptionModel` | String | The transcription model to select, by model ID. For example, `parakeet-tdt-0.6b-v3`. |
| `DefaultEnhancementProvider` | String | The AI enhancement provider to select, by name. For example, `VoiceInk Refine`, `Ollama`, or `Managed` for the [organization AI endpoint](#provide-an-organization-ai-endpoint). The endpoint's `ManagedAIProviderName` works too. |
| `DefaultEnhancementModel` | String | Optional. The model to select for that provider. VoiceInk ignores this key for VoiceInk Refine, which has one model, and for the organization endpoint, which uses `ManagedAIModel`. |
| `DefaultEnhancementEnabled` | Boolean | `true` turns on AI enhancement, and `false` turns it off. |
| `AutoDownloadModels` | Array of strings | Local models to download in the background. Use transcription model IDs, and `VoiceInk Refine V1` for VoiceInk Refine. |
| `ManagedDefaultsVersion` | Integer | Required to apply the choices. VoiceInk applies the choices once for each version. |

### How VoiceInk applies the defaults

- **Once per version.** VoiceInk applies the choices at launch and when the profile changes, and only when `ManagedDefaultsVersion` is greater than the last version it applied. It records the applied version in its own settings. After that, a user's changes stay, even across restarts. To push the choices again, raise the version.
- **After onboarding.** On a new install, VoiceInk applies the choices when the user finishes onboarding. The choices go into the default mode and the global model setting. Other modes keep their own settings.
- **Downloads.** VoiceInk starts each missing model in `AutoDownloadModels` in the background when it launches, and the user sees its progress in the model library. A download that fails starts again at the next launch. `AutoDownloadModels` is the only key that downloads anything, so list the default models there too.
- **Waiting for a download.** If the default transcription model hasn't been downloaded yet, VoiceInk keeps the current model and switches when the download finishes. It doesn't switch if the user chose another model in the meantime.
- **Onboarding.** When `DefaultTranscriptionModel`, `DefaultEnhancementProvider`, `DefaultEnhancementEnabled`, or `AutoDownloadModels` is set, onboarding skips entering an API key. It skips choosing a model too when the default transcription model, or another local model, is already downloaded. Otherwise it waits on the model step and continues to the practice steps when the download finishes. That step shows the default transcription model and its download progress, for any local model type; the user can start the download there if `AutoDownloadModels` doesn't list it. When the profile sets no local transcription model, the step offers Parakeet V3 instead. The permission and microphone steps stay, and the progress indicator counts only the steps shown.
- **Cloud services.** When `DisableCloudServices` is `true`, VoiceInk ignores a cloud model or cloud provider in these keys and writes a log message. Local choices still apply. If `DefaultEnhancementEnabled` is `true` and the provider is ignored, VoiceInk leaves enhancement as it was. VoiceInk still records the version as applied, so the ignored choices don't apply later on their own. If you remove `DisableCloudServices` and want them applied, raise `ManagedDefaultsVersion` too.
- **Organization endpoint.** When `DefaultEnhancementProvider` is `Managed`, VoiceInk selects the organization provider if `ManagedAIEndpointURL` and `ManagedAIModel` are set and the endpoint is allowed (with `DisableCloudServices` on, it must use `https` or a loopback host). VoiceInk doesn't check that the endpoint answers. Otherwise it selects VoiceInk Refine if the Mac can run it, writes a log message, and still applies `DefaultEnhancementEnabled`. On a Mac that can't run VoiceInk Refine either, VoiceInk ignores both keys.
- **No keys.** When none of these keys are set, VoiceInk behaves as it does without a profile.

### VoiceInk Refine on smaller Macs

VoiceInk Refine needs a Mac with Apple silicon and at least 16 GB of memory, and its download is about 1.1 GB. On an Intel Mac or a Mac with less memory, VoiceInk ignores VoiceInk Refine in `DefaultEnhancementProvider` and `AutoDownloadModels`, so it doesn't download the model or select it. It also ignores `DefaultEnhancementEnabled` set to `true`, so enhancement stays off unless the user turns it on. VoiceInk writes a log message for each ignored key that says why. The transcription default still applies. The same profile can go to every Mac; you don't need a separate profile for smaller Macs.

### Sample settings

The [sample profile](#sample-configuration-profile) sets these keys. It selects Parakeet for transcription and the organization AI endpoint for enhancement, and downloads VoiceInk Refine as the fallback for when the endpoint isn't set up or allowed. To use VoiceInk Refine alone, set `DefaultEnhancementProvider` to `VoiceInk Refine`.

The Parakeet model IDs are `parakeet-tdt-0.6b-v2` (English only) and `parakeet-tdt-0.6b-v3` (English and 25 European languages).

## Deny Screen Recording

VoiceInk asks for Screen Recording permission to read on-screen text for context-aware enhancement. To deny it, deploy a Privacy Preferences Policy Control (PPPC) profile with a `ScreenCapture` entry for VoiceInk set to deny. The entry needs the code requirement of the signed build you deploy. To get it, run this command against the installed app:

```sh
codesign -dr - /Applications/VoiceInk.app
```

Rebuilding or re-signing the app changes the code requirement, so update the PPPC profile whenever you deploy a build signed with a different identity.

## Test the key without a profile

To try the behavior on one Mac without MDM, set the key locally:

```sh
defaults write com.prakashjoshipax.VoiceInk DisableCloudServices -bool true
```

To go back to the default behavior, delete the key:

```sh
defaults delete com.prakashjoshipax.VoiceInk DisableCloudServices
```

A value set this way isn't managed, so users can change it the same way.

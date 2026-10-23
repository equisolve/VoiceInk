# Managed deployment

This page is for administrators who deploy VoiceInk with a mobile device management (MDM) service, such as Jamf Pro. It describes the preference keys that turn off cloud services, set up an organization AI endpoint, and set default models, and gives a sample configuration profile.

VoiceInk reads these keys from the preference domain that matches its bundle ID. Equisolve's release, built with `make equisolve-release` as described in [Equisolve release](../BUILDING.md#equisolve-release), has the bundle ID `com.equisolve.VoiceInk`, and this page uses that domain. A build with the upstream bundle ID, such as one from `make local`, reads the `com.prakashjoshipax.VoiceInk` domain instead.

## Turn off cloud services

Set the Boolean key `DisableCloudServices` to `true` in the `com.equisolve.VoiceInk` preference domain. When the key is `false` or absent, VoiceInk behaves exactly as it does without the key.

When the value comes from a configuration profile, users can't change it, and the app labels each hidden or turned-off option with **Managed by your organization**. When the value is set locally with `defaults write`, the app shows **Cloud services are turned off** instead.

VoiceInk applies a change to the key while it runs, so you don't need to restart the app. When cloud services turn off, VoiceInk moves off a cloud transcription model and open screens update. When they turn back on, VoiceInk returns to the model the user chose before. A streaming transcription that started before the change can finish.

### What the key blocks

When `DisableCloudServices` is `true`:

- **Cloud transcription.** Every non-local transcription provider is hidden from model pickers and refused before any audio is read or sent. This includes Groq, ElevenLabs, Deepgram, Mistral, Gemini, Soniox, Speechmatics, AssemblyAI, xAI, Cartesia, OpenRouter, custom transcription endpoints, and any cloud provider added in a later release. Only Whisper, Parakeet, transcribe.cpp, and Apple Speech models are available.
- **Modes that use a cloud transcription model.** VoiceInk uses the default transcription model if it's local and downloaded, otherwise the first downloaded local model. If no local model is downloaded, recording stops with an error that tells the user to choose a local model. Audio is never sent to a cloud service.
- **Cloud AI enhancement.** Only VoiceInk Refine, Ollama, custom OpenAI-compatible models, and the [organization AI endpoint](#provide-an-organization-ai-endpoint) are available. Ollama and custom models are allowed only when their server URL host is `localhost`, `127.0.0.1`, or `::1`, even when the URL points at the organization AI endpoint. VoiceInk refuses an Ollama server on another computer, including model listing and connection checks. The CLI provider is turned off, because the command it runs can reach cloud services. All other providers are hidden and refused before any text is sent.
- **Modes that use a blocked AI provider.** VoiceInk uses the organization AI endpoint when one is set up. Otherwise, it pastes the transcript without AI enhancement and shows a short notice with the reason.
- **API key entry.** The **Cloud** tab in **AI Models** shows a notice instead of the provider list, and onboarding skips the cloud provider steps. Keys already saved in the Keychain are ignored, not deleted, so they work again if the key is removed.
- **Auto-Learn Dictionary.** Auto-Learn requests go through the same check, so they can use only the allowed AI providers.
- **Model catalog refreshes.** VoiceInk doesn't download the OpenRouter model lists.

VoiceInk fully trusts an Ollama or custom endpoint on `localhost`, `127.0.0.1`, or `::1`, including any redirect or forwarding that server does. For example, a local proxy such as LiteLLM can accept a request on `localhost` and send it to a cloud service, and VoiceInk follows a redirect from a local server to another host. Allow only local servers that you control.

### What the key doesn't block

The key covers transcription and AI enhancement. These network connections aren't affected:

- Downloads of local models (Whisper, Parakeet, transcribe.cpp, and VoiceInk Refine).
- Signing in with Equisolve, which goes only to `ManagedAISignInURL`, as described in [Let each person sign in](#let-each-person-sign-in).
- Update checks through Sparkle, in builds that have an update feed. Equisolve's release has none, so it never checks for updates. In other builds, set `VoiceInkChecksForUpdatesOnLaunch` to `false` to turn off automatic checks.
- In-app announcements. To turn them off, set `enableAnnouncements` to `false`.
- License activation and validation, in builds that check a license. Equisolve's release doesn't.

## Provide an organization AI endpoint

To give users AI enhancement through a service your organization runs, set these keys in the `com.equisolve.VoiceInk` domain. The endpoint must accept OpenAI-compatible chat completion requests.

| Key | Type | Value |
| --- | --- | --- |
| `ManagedAIEndpointURL` | String | The base URL of the API, such as `https://ai.example.com/v1`. VoiceInk sends requests to `chat/completions` under it. A URL that already ends in `/chat/completions` is used as is. VoiceInk ignores a URL that has a user name, password, query, or fragment; put credentials in `ManagedAIToken`. |
| `ManagedAIModel` | String | The model name to send with each request. |
| `ManagedAISignInURL` | String | The Hourglass URL people sign in to for their own key, such as `https://hourglass.intra.equisolve.com`. Optional. See [Let each person sign in](#let-each-person-sign-in). The URL must use `https`, and VoiceInk ignores a URL that has a user name, password, query, or fragment. |
| `ManagedAIToken` | String | The token to send in an `Authorization: Bearer` header. Optional, and meant for setups without sign-in. When it's set, VoiceInk sends it instead of anyone's signed-in key. |
| `ManagedAIProviderName` | String | The provider name users see. Optional. The default is **Organization AI**. Avoid the name of a built-in provider, such as `OpenAI`: `DefaultEnhancementProvider` always reads a built-in name as that provider. |

When `ManagedAIEndpointURL` and `ManagedAIModel` are both set:

- The **Cloud** tab in **AI Models** shows the provider, model, and endpoint as read-only, labeled **Managed by your organization** when the values come from a configuration profile. The token itself isn't shown.
- The provider is first in the AI provider lists. Setting or changing the endpoint doesn't change which provider users have selected; to select it for them, use `DefaultEnhancementProvider`.
- VoiceInk reads the token for each request. It doesn't copy the token to the Keychain, logs, or history. Without a token, VoiceInk sends no `Authorization` header.
- Changes to these keys apply while the app runs.
- To make the provider the default for enhancement, set `DefaultEnhancementProvider` to `Managed`, as described in [Set default models](#set-default-models).

Each request is a `POST` to `chat/completions` with the default cleanup prompt and the custom vocabulary as the system message, and the transcript as the user message, the same as other OpenAI-compatible providers. The body has only `model`, `messages`, and `stream` (`false`). VoiceInk doesn't send `temperature` or other sampling settings, because some models reject them: Claude Haiku 5.5 on Amazon Bedrock rejects a request that sets `temperature`. Set sampling options on the proxy if you need them.

VoiceInk follows a redirect from the endpoint only when it keeps the endpoint's scheme, host, and port. It refuses any other redirect and reports an error, so the token isn't sent to another server. This applies whether or not `DisableCloudServices` is set.

### Let each person sign in

When `ManagedAISignInURL` is set, each person signs in with their Equisolve account to get their own key for the endpoint, so you don't put a shared token in the profile. The provider card on the **Cloud** tab in **AI Models**, and the **Try Enhancement** step in onboarding, show a **Sign in with Equisolve** button. After the person signs in, the card shows **Signed in as** and the account name, with a **Sign Out** button.

Sign-in works like this:

1. VoiceInk opens `<ManagedAISignInURL>/oauth/authorize` in the default browser. The request uses the OAuth 2.0 authorization code flow with PKCE (`S256`), the client ID `voiceink-mac`, and the scope `voiceink`.
1. The person signs in to Hourglass. Hourglass sends the browser back to `http://127.0.0.1:<port>/oauth/callback`, where VoiceInk listens on a port the system picks, on this Mac only. The browser shows a page that says the tab can be closed. VoiceInk stops listening after five minutes if the browser doesn't come back.
1. VoiceInk checks the `state` value. It answers a request with any other `state` with an error page and keeps listening, so another program on the Mac can't end the sign-in. Then VoiceInk sends the code to `<ManagedAISignInURL>/oauth/token` and gets an Hourglass access token.
1. VoiceInk sends the access token to `<ManagedAISignInURL>/api/voiceink/key` and gets the person's key and account name. It then discards the access token, which it never saves or logs.

What VoiceInk stores and sends:

- The key and the account name are stored together in one item in the person's login Keychain. The item isn't synced to other Macs. Sign Out deletes it.
- Each request to the endpoint sends `ManagedAIToken` if the profile sets it, otherwise the signed-in key. When sign-in is set up and the person hasn't signed in, VoiceInk sends nothing to the endpoint. AI enhancement shows **Sign in with Equisolve to use AI cleanup** and pastes the transcript without changes.
- When the endpoint answers `401 Unauthorized` to the signed-in key, VoiceInk deletes the key, and a notification asks the person to sign in again.
- VoiceInk sends the signed-in key only while `ManagedAISignInURL` is set. If you remove `ManagedAISignInURL` from the profile, VoiceInk stops sending a saved key, but doesn't delete it.
- Requests to the sign-in server follow redirects only within the `ManagedAISignInURL` scheme, host, and port.

To revoke a person's key, revoke it in Hourglass **Settings**, or deactivate the person in Hourglass. A deactivated account can't sign in to get a new key. Signing out in VoiceInk deletes only the copy on that Mac.

Changes to `ManagedAISignInURL` apply while the app runs.

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

- VoiceInk sends text only to the organization provider and to Ollama and custom models on loopback hosts. A custom model or Ollama server whose URL points at the endpoint is still refused, because only the organization provider limits where the token and redirects go.
- The endpoint must use `https` unless its host is `localhost`, `127.0.0.1`, or `::1`. VoiceInk refuses an `http` endpoint on another host, so the token is never sent unencrypted.
- When the selected provider or the default mode's provider is blocked, VoiceInk switches both to the organization provider. Other modes set to a blocked provider use the organization provider when they run.
- Transcription is unchanged. Only local transcription models are available.

When `DisableCloudServices` is `false` or absent, the organization provider is added to the providers users already have, and every other provider stays available.

**Warning:** Any user or process on the Mac can read a value delivered in a configuration profile, including `ManagedAIToken`. Use a token that works only with your proxy and that you can revoke, never an API key for an AI provider. To avoid a shared token, use [sign-in](#let-each-person-sign-in) instead.

## Other useful keys

All of these keys are in the `com.equisolve.VoiceInk` domain.

| Key | Type | Effect |
| --- | --- | --- |
| `DisableCloudServices` | Boolean | `true` turns off cloud transcription and cloud AI enhancement, as described on this page. |
| `ManagedAIEndpointURL`, `ManagedAIModel`, `ManagedAISignInURL`, `ManagedAIToken`, `ManagedAIProviderName` | String | Set up an organization AI endpoint, as described in [Provide an organization AI endpoint](#provide-an-organization-ai-endpoint). |
| `IsAutoLearnDictionaryEnabled` | Boolean | `false` turns off Auto-Learn Dictionary. |
| `enableAnnouncements` | Boolean | `false` turns off in-app announcements. |
| `HideGitHubStarPrompt` | Boolean | `true` hides the request to star VoiceInk on GitHub, both the Dashboard card and the Dashboard footer button. Settings shows **Show GitHub Star Request** turned off and labeled **Managed by your organization**. When the key is `false` or absent, each person's **Show GitHub Star Request** setting decides. |
| `VoiceInkChecksForUpdatesOnLaunch` | Boolean | `false` turns off automatic update checks. Equisolve's release never checks, so the key has no effect there. |
| `IsTranscriptionCleanupEnabled` | Boolean | `true` deletes transcripts and recordings after the retention period. |
| `TranscriptionRetentionMinutes` | Integer | How long to keep transcripts and recordings, in minutes, when cleanup is on. For example, `10080` is seven days. |

## Sample configuration profile

This profile sets the keys in the previous table, except `ManagedAIToken`, and the [default models](#set-default-models): Parakeet for transcription and the organization AI endpoint for enhancement, with VoiceInk Refine downloaded as the fallback. Each person signs in with Equisolve to get their own key. Auto-Learn Dictionary stays off. Replace the `ManagedAI` values with your endpoint, model, and sign-in URL. For a setup without sign-in, replace `ManagedAISignInURL` with `ManagedAIToken`. If you don't run an AI endpoint, remove the `ManagedAI` keys and set `DefaultEnhancementProvider` to `VoiceInk Refine`. Upload it to your MDM service as a custom configuration profile, or paste the inner dictionary under `mcx_preference_settings` into a custom settings payload for the `com.equisolve.VoiceInk` domain. Replace the `PayloadUUID` values with your own (run `uuidgen`), and change `PayloadIdentifier` and `PayloadOrganization` to match your organization.

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
                <key>com.equisolve.VoiceInk</key>
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
                                <key>ManagedAISignInURL</key>
                                <string>https://hourglass.example.com</string>
                                <key>ManagedAIProviderName</key>
                                <string>Example AI</string>
                                <key>IsAutoLearnDictionaryEnabled</key>
                                <false/>
                                <key>enableAnnouncements</key>
                                <false/>
                                <key>HideGitHubStarPrompt</key>
                                <true/>
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
defaults read com.equisolve.VoiceInk DisableCloudServices
```

The command prints `1` when cloud services are off.

## Set default models

These keys set starting choices that users can change later. They are separate from the keys in the previous table: a profile forces every key it sets, so VoiceInk reads these keys and copies their values into its own settings, which stay editable.

| Key | Type | Effect |
| --- | --- | --- |
| `DefaultTranscriptionModel` | String | The transcription model to select, by model ID. For example, `parakeet-tdt-0.6b-v3`. |
| `DefaultEnhancementProvider` | String | The AI enhancement provider to select, by name. For example, `VoiceInk Refine`, `Ollama`, or `Managed` for the [organization AI endpoint](#provide-an-organization-ai-endpoint). The endpoint's `ManagedAIProviderName` works too, unless it's the name of a built-in provider. |
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

For Equisolve's release, the identifier is `com.equisolve.VoiceInk`, the identifier type is bundle ID, and the code requirement is:

```text
identifier "com.equisolve.VoiceInk" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = "3MMFZ6XFFA"
```

This requirement names the bundle ID and Equisolve's team, not a single build, so it stays the same across Equisolve releases. A build signed with a different identity, or with a different bundle ID, has a different code requirement and needs its own PPPC entry.

## Test the key without a profile

To try the behavior on one Mac without MDM, set the key locally:

```sh
defaults write com.equisolve.VoiceInk DisableCloudServices -bool true
```

To go back to the default behavior, delete the key:

```sh
defaults delete com.equisolve.VoiceInk DisableCloudServices
```

A value set this way isn't managed, so users can change it the same way.

The other keys on this page work the same way. For example, to try the organization endpoint with sign-in:

```sh
defaults write com.equisolve.VoiceInk ManagedAIEndpointURL https://ai.example.com/v1
defaults write com.equisolve.VoiceInk ManagedAIModel voiceink-cleanup
defaults write com.equisolve.VoiceInk ManagedAISignInURL https://hourglass.example.com
```

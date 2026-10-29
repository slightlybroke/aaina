# Local voice playback patch

Source: flutter_pcm_sound 3.3.3, https://pub.dev/packages/flutter_pcm_sound/versions/3.3.3
Upstream: https://github.com/chipweinberger/flutter_pcm_sound
License retained in LICENSE. Only runtime package files are vendored (no examples/site).

Android AudioTrack uses USAGE_VOICE_COMMUNICATION / CONTENT_TYPE_SPEECH rather than
USAGE_MEDIA / CONTENT_TYPE_MUSIC. This matches the recorder's VOICE_COMMUNICATION source
and MODE_IN_COMMUNICATION, making playback eligible for the device communication path and
echo reference. This does not guarantee effective acoustic echo cancellation on every device.
The pre-API-23 fallback is unchanged; the app's supported Android floor is above that path.
iOS/macOS runtime source is unchanged. No recording, network or logging additions.

Android API 31+ also explicitly selects TYPE_BUILTIN_SPEAKER through
AudioManager.setCommunicationDevice, then clears this app's selection on cleanup/detach.
Setup reports a routing error if no speaker is available or selection is rejected.
This app declares the normal MODIFY_AUDIO_SETTINGS permission needed for communication
routing/mode. Older Android continues using the recorder's legacy speakerphone setting.
This is a speakerphone flow; headset/Bluetooth routing is not offered or verified.

The SDK-36 Gradle override remains scoped in android/build.gradle.kts. Do not edit global
pub-cache files. On upstream upgrade, review whether this patch is still required and test
speakerphone double-talk, interruption, Stop/background, and previous photo flows on-device.

Official reference: https://developer.android.com/reference/android/media/AudioAttributes

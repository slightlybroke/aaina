# aaina Flutter client

See the root README for Supabase setup, public environment configuration, API/worker commands,
and the distinction between mocked checks and live acceptance.

## Offline photo-input checks

Gallery images are read through XFile, decoded on the device, validated without upscaling,
and prepared as JPEG before explicit upload. Camera capture uses an in-app preview with a
front-lens default, a front/rear switch and an available-camera fallback. There is no silent
gallery-to-camera fallback. These checks do not require a running API or a YouCam request.

```powershell
flutter analyze --no-pub
flutter test --no-pub --timeout 60s
flutter devices
adb -s DEVICE_ID push test/fixtures/gallery.webp /sdcard/Download/beauty-picker-test.webp
adb -s DEVICE_ID shell am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d file:///sdcard/Download/beauty-picker-test.webp
flutter test integration_test/photo_inputs_device_test.dart -d DEVICE_ID --no-pub --dart-define=MANUAL_GALLERY_CHECK=true
```

On the test phone, allow camera access if requested. The offline harness opens previews,
switches lenses and cancels; its shutter is disabled. Then select only the green/blue synthetic
fixture once and cancel once, in either order. It checks real local decoding
and file access but has no upload client. Permission denial/no-camera behavior also has
widget-test coverage. Native behavior on other devices and iOS requires its own test run.

The device harness temporarily replaces the debug app. Restore the normal entry point after
testing, retaining app data:

```powershell
flutter build apk --debug --no-pub --dart-define-from-file=.env
adb -s DEVICE_ID install -r build/app/outputs/flutter-apk/app-debug.apk
```

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

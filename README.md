# Zikr Modern — Premium Islamic Tasbeeh

A single-file Flutter app (`lib/main.dart`) implementing:

- **Home** — circular tap-to-count counter, swipe left/right to switch between 6 dhikr
  presets, Auto Tasbeeh-e-Fatima mode (33 → 33 → 34 with auto-switch + vibration),
  streak tracker, Giant Mode, reset with undo snackbar, target editor, shake-to-undo,
  confetti + TTS + heavy vibration on target completion.
- **Mood** — pick a mood, get a matched dhikr (Alhamdulillah / Astaghfirullah /
  Hasbunallah / La hawla wala quwwata / La ilaha illallah) with target 100, "Start Dhikr"
  jumps to Home; mood history saved locally.
- **Circle (Group Khatm)** — create/join a circle, live Firestore-backed progress ring,
  member avatars, live activity feed, Add Count / Share Progress. Falls back to a clear
  offline message (Home tab keeps working) if Firebase isn't configured.
- **Settings** — volume-button counting (up/down), Ghost Overlay Bubble toggle +
  permission request, AOD (Always On Display) full-black mode, Giant Mode, sound/vibration
  toggles, daily reminder time picker, offline/no-ads/no-tracking trust badge.

All state (count, target, dhikr index, toggles, streak, mood history) persists via
`SharedPreferences`.

## Building via GitHub Actions (no local Flutter install needed)

This repo includes `.github/workflows/build-apk.yml`. Just push this whole folder
to a GitHub repo (as-is, `lib/main.dart` + `pubspec.yaml` at the repo root, no
`android/` or `ios/` folder needed) and push to `main`, or run the workflow
manually from the **Actions** tab. It will:

1. Set up Java 17 + Flutter stable.
2. Run `flutter create` to generate the native `android/`/`ios/` scaffolding
   (only if `android/` doesn't already exist), then restore your `lib/main.dart`
   and `pubspec.yaml` over the generated defaults.
3. Patch `AndroidManifest.xml` with the overlay/wakelock/vibration/notification
   permissions and the overlay service tag.
4. Set `minSdkVersion` to 26 (required for `flutter_tts` / `flutter_overlay_window`).
5. `flutter pub get`, `flutter analyze` (non-blocking), then
   `flutter build apk --debug`.
6. Upload the APK as a workflow artifact named `zikr-modern-debug-apk` — download
   it from the finished run's **Artifacts** section.

Release (Play Store) signing isn't set up by default — add a signing config via
GitHub Secrets when you're ready for a release build; the debug build above is
enough to install and test on a device.

## Local setup (alternative)

```bash
flutter create --org com.afzal --project-name zikr_modern .
# (or drop lib/main.dart + pubspec.yaml into an existing Flutter project)
flutter pub get
```

1. **Android permissions**: merge `android_manifest_snippet.xml` into
   `android/app/src/main/AndroidManifest.xml` (permissions above `<application>`,
   the overlay `<service>` inside it).
2. **Firebase (optional, for Circle/Group Khatm)**: run `flutterfire configure` to
   generate `firebase_options.dart`, then initialize it in `main()` instead of the
   bare `Firebase.initializeApp()` call, and enable Anonymous Auth + Firestore in the
   Firebase console. Every other screen works with zero Firebase setup.
3. **Minimum SDK**: set `minSdkVersion 26` (Android 8+) in `android/app/build.gradle`
   for `flutter_tts` / `flutter_overlay_window` compatibility.
4. Run: `flutter analyze` then `flutter run`.

## Notes / next steps

- Volume-button counting while the screen is off/locked and the daily reminder's
  exact-alarm scheduling both need a small platform channel / background service —
  this file wires the UI and preference storage for them; hook the native side up
  per `flutter_overlay_window`'s and `flutter_local_notifications`' own setup docs.
- The Ghost Overlay's actual bubble UI (a second, tiny Flutter entrypoint drawn by
  `flutter_overlay_window`) is toggled and permission-requested here; add an
  `overlayMain()` entrypoint per that package's README to draw the bubble content.
- No placeholder business logic: counting, dhikr switching, Fatima auto-mode, mood
  mapping, streaks, settings persistence, and the Circle Firestore reads/writes are
  all live.

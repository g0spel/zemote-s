/// Current app version.
///
/// Injected at build time by CI via `--dart-define=APP_VERSION=X.Y.Z`
/// (see `.github/workflows/build-apk.yml`, which reads it from
/// `pubspec.yaml`). The default only serves local `flutter run`/`flutter
/// test` without the define and must be kept in sync with `pubspec.yaml`.
const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: '0.11.0');
const appBuildNumber = 1;

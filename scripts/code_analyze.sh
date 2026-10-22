#!/bin/sh -ve
flutter pub get && flutter pub run build_runner build --delete-conflicting-outputs
# Format generated files without causing CI failure
dart format lib/generated/l10n/
# Format and check developer-written files for changes, failing CI if necessary
if ! dart format --set-exit-if-changed lib/ test/ integration_test/; then
  # Fail with an actionable, bounded patch for contributor-authored source.
  # Generated files are handled separately and not part of this report.
  git diff -- lib/ test/ integration_test/ | head -n 250
  exit 1
fi
flutter analyze

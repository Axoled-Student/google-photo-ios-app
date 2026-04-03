# Google Photo Sync

Google Photo Sync is a SwiftUI iOS app that signs into Google, reads the user's
Apple Photos library, and uploads photos and videos into an app-created album
in Google Photos with live progress, throughput-based ETA, and a recent uploads
feed.

## What is in this repo

- A new SwiftUI iOS app scaffold generated with XcodeGen.
- Google OAuth login via AppAuth.
- Apple Photos permission and asset enumeration.
- Incremental sync with a local manifest to avoid duplicate uploads.
- A polished dashboard showing:
  - overall percentage
  - uploaded items out of total items
  - uploaded bytes out of estimated total bytes
  - current file name
  - estimated remaining time
- GitHub Actions for project generation and build verification.

## Important OAuth note

The `client_secret.json` used earlier for the Python smoke test is a desktop
OAuth credential. Do not embed that file in an iOS app.

This SwiftUI app uses AppAuth with a native iOS OAuth client, so you do not
need to ship any new JSON file inside the app. Instead, create an iOS-native
OAuth client in Google Cloud and set these values in `Config/Base.xcconfig`:

```xcconfig
GOOGLE_CLIENT_ID = your-ios-client-id.apps.googleusercontent.com
GOOGLE_REDIRECT_SCHEME = com.googleusercontent.apps.your-ios-client-id
GOOGLE_REDIRECT_URI = com.googleusercontent.apps.your-ios-client-id:/oauthredirect
GOOGLE_PHOTOS_ALBUM_TITLE = Camera Roll Backup
```

The redirect scheme in `Info.plist` must match the iOS OAuth client you create
in Google Cloud.

If you prefer using the Google Sign-In SDK instead of AppAuth, that would be a
different integration and would typically use a different client configuration.
The current codebase is already wired for AppAuth, so the `xcconfig` values are
the only app credentials you need to add.

## Google Cloud setup

1. Create or select a Google Cloud project.
2. Enable the Google Photos API.
3. Configure the OAuth consent screen and add your Google account as a test user.
4. Create an OAuth client for iOS.
5. Copy the client ID and redirect values into `Config/Base.xcconfig`.

## Local build

1. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen).
2. Run `xcodegen generate`.
3. Open `GooglePhotoSync.xcodeproj`.
4. Build and run on an iPhone or simulator signed into your Apple developer account.

## Source layout

- `GooglePhotoSync/App`: SwiftUI app entry.
- `GooglePhotoSync/Features`: dashboard UI and sync coordinator.
- `GooglePhotoSync/Services`: Google OAuth, Google Photos uploads, Photos access,
  keychain persistence, and manifest storage.
- `GooglePhotoSync/Core` and `GooglePhotoSync/Models`: configuration and shared
  data types.

## Background behavior

The app automatically starts syncing after Google sign-in and Photos permission.
It also watches the photo library for changes and schedules another sync pass
when new items appear.

Because iOS strictly limits background execution, "auto sync" is best-effort.
The app is designed to resume quickly and continue incremental uploads, but iOS
does not guarantee unlimited background time for large libraries.

## GitHub Actions

The workflow in `.github/workflows/ios.yml` installs XcodeGen, generates the
project, resolves Swift packages, and builds the app on a macOS runner.

## Security

The personal access token shared in chat was not used anywhere in this repo.
Revoke and rotate it in GitHub because it was exposed in conversation.

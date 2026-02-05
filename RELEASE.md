# Release Setup for Voxtral Menu Bar Transcriber

This document describes how to set up the automated release workflow for GitHub Releases.

## Overview

The release workflow (`/.github/workflows/release.yml`) automatically:
- Builds the app from Xcode project
- Code signs with Developer ID certificate
- Notarizes with Apple
- Creates DMG and ZIP distribution artifacts
- Publishes to GitHub Releases with release notes

## Bundled Python Runtime

The backend bundle uses python-build-standalone and is pinned to Python 3.12.x because vllm-metal publishes cp312 wheels. If vllm-metal adds support for newer Python versions, update `VoxtralMenuBar/BundleBackend.sh` and `backend/pyproject.toml` together.

## Required GitHub Secrets

Configure these secrets in your GitHub repository settings (Settings → Secrets and variables → Actions):

### Apple Developer Code Signing

| Secret Name | Description |
|-------------|-------------|
| `CERTIFICATE_BASE64` | Base64-encoded Developer ID Application certificate (.p12 file) |
| `CERTIFICATE_PASSWORD` | Password for the certificate |
| `KEYCHAIN_PASSWORD` | Temporary keychain password (can be arbitrary) |

### Apple Notarization

| Secret Name | Description |
|-------------|-------------|
| `APPLE_ID` | Your Apple ID email address |
| `APPLE_ID_PASSWORD` | App-specific password for notarization (generate at appleid.apple.com) |
| `APPLE_TEAM_ID` | Your Apple Developer Team ID (10-character string) |

## Setup Instructions

### 1. Create Developer ID Certificate

1. Open Xcode on a Mac with Apple Developer account
2. Go to Xcode → Settings → Accounts
3. Select your Apple Developer account
4. Choose "Create a Developer ID Application certificate" from the gear menu
5. Download the certificate

### 2. Export Certificate as P12

1. Open Keychain Access
2. Find your "Developer ID Application" certificate
3. Expand to show the private key
4. Right-click the private key → Export
5. Save as `.p12` file with a password
6. Convert to base64:
   ```bash
   base64 -i certificate.p12 | pbcopy
   ```
7. Paste the output into GitHub Secret `CERTIFICATE_BASE64`

### 3. Generate App-Specific Password for Notarization

1. Go to [appleid.apple.com](https://appleid.apple.com)
2. Sign in with your Apple ID
3. Go to "Security" → "App-Specific Passwords"
4. Generate a new password for notarization
5. Use this as `APPLE_ID_PASSWORD`

### 4. Find Your Team ID

1. Go to [developer.apple.com/account](https://developer.apple.com/account)
2. Your Team ID is displayed in the membership details
3. Or run: `xcrun altool --list-providers -u "your@email.com"`
4. Use this as `APPLE_TEAM_ID`

### 5. Add Secrets to GitHub

1. Go to your repository on GitHub
2. Settings → Secrets and variables → Actions
3. Click "New repository secret" for each secret:
   - `CERTIFICATE_BASE64` (paste base64 certificate)
   - `CERTIFICATE_PASSWORD` (certificate export password)
   - `KEYCHAIN_PASSWORD` (arbitrary, use a random string)
   - `APPLE_ID` (your Apple ID email)
   - `APPLE_ID_PASSWORD` (app-specific password)
   - `APPLE_TEAM_ID` (10-character team ID)

## Creating a Release

### Automated Release (Git Tag)

Push a version tag to trigger the workflow:

```bash
git tag v1.0.0
git push origin v1.0.0
```

The workflow will:
1. Build and sign the app
2. Notarize with Apple
3. Create DMG and ZIP artifacts
4. Create a GitHub Release with download links

### Manual Release

1. Go to Actions tab in GitHub
2. Select "Release" workflow
3. Click "Run workflow"
4. Optionally use a specific branch

## Release Artifact Verification

After downloading a release, verify code signature:

```bash
codesign -dv --verbose=4 /path/to/VoxtralMenuBar.app
```

Verify notarization:

```bash
spctl -a -vvv /path/to/VoxtralMenuBar.app
```

## Local Testing

To test the release process locally without pushing a tag:

```bash
# Build and archive
xcodebuild archive \
  -project VoxtralMenuBar.xcodeproj \
  -scheme VoxtralMenuBar \
  -archivePath build/VoxtralMenuBar.xcarchive

# Export app (set APPLE_TEAM_ID environment variable)
xcodebuild -exportArchive \
  -archivePath build/VoxtralMenuBar.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist ExportOptions.plist \
  APPLE_TEAM_ID="YOUR_TEAM_ID"

# Notarize (requires notarytool credentials)
xcrun notarytool submit build/export/VoxtralMenuBar.app \
  --apple-id "your@email.com" \
  --password "app-specific-password" \
  --team-id "TEAMID" \
  --wait

# Staple ticket
xcrun stapler staple build/export/VoxtralMenuBar.app
```

## Troubleshooting

### Certificate Issues

- Error: "No suitable signing certificates found"
  - Verify certificate is added to GitHub Secrets
  - Check certificate hasn't expired
  - Verify CERTIFICATE_PASSWORD is correct

### Notarization Fails

- Error: "App-specific password required"
  - Generate a new app-specific password at appleid.apple.com

- Error: "Invalid team ID"
  - Verify team ID matches your Apple Developer account

### Build Failures

- Xcode version issues: Workflow uses latest macOS with Xcode pre-installed
- Missing dependencies: All dependencies should be in Xcode project

## Privacy Policy

The app is fully local and does not collect or transmit data (except optional Gemini rewrite feature with explicit opt-in). Ensure your GitHub repository includes a clear privacy statement.

## Versioning

Follow Semantic Versioning:
- MAJOR.MINOR.PATCH (e.g., 1.0.0)
- Prepend `v` for git tags (e.g., `v1.0.0`)
- Update CFBundleShortVersionString in `VoxtralMenuBar/Info.plist` for each release

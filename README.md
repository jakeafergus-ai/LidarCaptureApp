# LidarCaptureApp

Personal capture app: synchronized video + LiDAR depth + IMU, built and deployed without a Mac.

## Milestone 0 status

Project scaffold is in place: `project.yml` (XcodeGen spec), a minimal SwiftUI screen, and
`.github/workflows/build-unsigned-ipa.yml` which builds an unsigned `.ipa` on a GitHub-hosted
macOS runner. This proves the full zero-Mac pipeline before any camera code is written.

## One-time setup (manual, needs your GitHub account)

1. Create a new **public** GitHub repository (public is required for unlimited free macOS Actions
   minutes — private repos get a small monthly allowance and macOS runners burn it at 10x the
   normal rate).
2. From this folder:
   ```
   git remote add origin https://github.com/<your-username>/LidarCaptureApp.git
   git push -u origin main
   ```
3. On GitHub, go to the **Actions** tab — the `Build Unsigned IPA` workflow should run
   automatically on push (or trigger it manually via "Run workflow").
4. When it finishes, download the `LidarCaptureApp-unsigned-ipa` artifact from the workflow run.

## Installing on your iPhone

1. Install [Sideloadly](https://sideloadly.io) on your Windows laptop.
2. Connect your iPhone via USB.
3. Drag the downloaded `.ipa` into Sideloadly, enter your free Apple ID, and install.
4. On the phone: Settings → General → VPN & Device Management → trust the developer profile.
5. Free Apple ID signing expires after 7 days — re-run Sideloadly to reinstall/refresh when it does.

## Getting data off the phone later

Once the app is capturing real sessions, each recording folder will be visible directly in the
iOS **Files** app (under "On My iPhone → LidarCaptureApp") — no USB or cloud step required just to
browse it. From there, use the Files app's own Share sheet to export a session to OneDrive.

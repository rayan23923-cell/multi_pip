# Testing TaskLens on a real iPhone without a Mac

The Debug build includes the **Video PiP Lab** (Settings > Developer), which
tests YouTube's embedded player, native Picture in Picture and the YouTube
app on the device, and logs every step.

## 1. Build the IPA on Codemagic

1. Sign in at codemagic.io with GitHub and add the `multi_pip` repository.
2. Choose the `codemagic.yaml` configuration, branch `claude/project-thread-0s4dmt`.
3. Start the workflow **TaskLens device lab (unsigned IPA)**.
4. When it finishes, download `TaskLens-DeviceLab.ipa` from the build's artifacts.

The build is unsigned. Bundle IDs start with `BUNDLE_PREFIX`
(`com.tasklens.devicelab` by default; change it in the workflow's environment
variables if Sideloadly reports the ID is taken).

## 2. Install with Sideloadly (Windows)

1. Install iTunes and iCloud **from apple.com** (not the Microsoft Store versions).
2. Install Sideloadly from sideloadly.io.
3. Connect the iPhone by USB and tap **Trust** on the iPhone.
4. Drag `TaskLens-DeviceLab.ipa` into Sideloadly, enter your Apple ID, press **Start**.
5. On the iPhone:
   - Settings > Privacy & Security > **Developer Mode** on (the iPhone restarts).
   - Settings > General > VPN & Device Management > your Apple ID > **Trust**.

With a free Apple ID the app works for 7 days; install again to renew.
If signing the extensions fails, use Sideloadly's advanced option to remove
app extensions: the app and the lab work without them (only sharing from
other apps and the widget are missing).

## 3. Run the lab

TaskLens > Settings tab > Developer > **Video PiP Lab**. Follow the checklist
at the bottom of the screen, then tap **Copy Log** and send the log back.

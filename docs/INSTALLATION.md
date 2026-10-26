# Installing Relvora

Relvora runs on **macOS 26 or later**, on both Apple silicon and Intel Macs.

## Install a release

1. Download `Relvora-<version>.zip` from the repository's **Releases** page.
2. Optional: check the download against the `.sha256` file next to it.

   ```sh
   shasum -a 256 -c Relvora-1.2.0.zip.sha256
   ```

3. Double-click the zip and move **Relvora.app** to **Applications**.
4. Open it. Release builds are signed with Developer ID and notarized, so macOS opens them without a warning ([DISTRIBUTION.md](DISTRIBUTION.md)).

## Updates

Relvora updates itself from the next release after 0.1.2 ([ADR 0017](decisions/0017-update-relvora-from-relvora.md)):

- It checks the repository's releases at launch and once a day, with your GitHub sign-in. A newer version appears at the bottom of the sidebar. **Relvora › Check for Updates…** checks right away.
- **Install and Relaunch** does the rest:
  - saves a backup of your data (Safety Backups);
  - downloads the zip and checks it against the release's checksum;
  - installs it only if Apple notarized it and it's signed by the same developer as your copy;
  - reopens Relvora.
  - The previous version goes to the Trash.
- Turn automatic checks off in **Settings › General › Updates**.

Updates need a GitHub sign-in that can read the repository. Relvora must also run from a folder you can change, such as Applications: not from a disk image, and not from Downloads, where macOS runs a temporary copy.

To update by hand, quit Relvora and replace the app in Applications. Your projects, release history, and settings stay. **0.1.2 and older** have no updater, so install the first version with it this way.

## Build from source

You need Xcode 26 (validated with Xcode 26.6) and no other tools.

```sh
git clone git@github.com:erickpea29/Release-Manager.git
cd Release-Manager
open Relvora.xcodeproj          # then Product › Run (⌘R)
```

Or from Terminal:

```sh
xcodebuild -project Relvora.xcodeproj -scheme Relvora -destination "platform=macOS,arch=arm64" \
  -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/Relvora.app
```

How the build is signed:
- **Without extra setup**, builds are ad-hoc signed as `com.erickpea29.Relvora.adhoc`.
- **To sign with your own Apple Development certificate**, run `cp Config/Local.xcconfig.example Config/Local.xcconfig` and set your team. Builds are then signed as `com.erickpea29.Relvora.dev`, and Keychain access survives rebuilds without prompts.

Each build type keeps its own data. Move data between them with a backup ([ADR 0007](decisions/0007-build-configuration-and-signing.md)).

To run the tests:

```sh
cd Packages/RelvoraKit && swift test                                    # domain, storage, GitHub client
xcodebuild test -project Relvora.xcodeproj -scheme Relvora \
  -destination "platform=macOS,arch=arm64"                               # UI tests (in-memory, demo GitHub)
```

## First launch

1. Create a project with **File › New Project…** (⇧⌘N). New projects start with the columns set in **Settings › Board**.
   Plan its first version (**New Release Plan…**): the **Board** shows that version's tasks, and the **Backlog** tab holds everything else.
2. Connect GitHub in **Settings › GitHub › Connect GitHub…**:
   1. Relvora shows a one-time code. Choose **Copy Code and Open GitHub**.
   2. Approve the request on github.com.
   3. Relvora stores the sign-in in your Keychain. It uses no password and no server.
3. Install the **Relvora** GitHub App on the repositories you release from. Use the **Add repositories on GitHub…** link in the repository picker. To register your own GitHub App instead, see [GITHUB_APP_SETUP.md](GITHUB_APP_SETUP.md).
4. In the project, open the **GitHub** tab and click **Connect Repository…**.

Press **⌘K** at any time to jump to a project or run an action.

## Back up and recover

- **File › Export Backup…** (⇧⌘E) saves all projects, release history, and settings to one JSON file.
- **File › Restore from Backup…** checks the file first and saves a safety copy before replacing anything.
- Details and a recovery checklist: [BACKUP_AND_RESTORE.md](BACKUP_AND_RESTORE.md).

If Relvora can't open its data at launch, it shows a recovery screen instead of crashing. Quit it, then restore your latest backup.

## Where Relvora keeps things

| What | Where |
|---|---|
| Projects, boards, release plans, history | `~/Library/Containers/com.erickpea29.Relvora/Data/Library/Application Support/Relvora/Relvora.store` |
| Cached GitHub data (re-downloadable) | Same folder, `GitHub Cache/` |
| Safety copies made before a restore | Same folder, `Safety Backups/` |
| Settings | The app's preferences (in the same container) |
| GitHub sign-in | Your login Keychain, item `com.erickpea29.Relvora.github` |

For development builds, replace `com.erickpea29.Relvora` with `com.erickpea29.Relvora.dev` or `com.erickpea29.Relvora.adhoc`.

## Uninstall

1. Export a backup if you might want your data later.
2. Choose **Settings › GitHub › Disconnect…**, then revoke Relvora on github.com under **Settings › Applications › Authorized GitHub Apps**.
3. Delete **Relvora.app** and the folder `~/Library/Containers/com.erickpea29.Relvora`.

## Troubleshooting

| Problem | What to do |
|---|---|
| "Relvora can't be opened" (unsigned test builds only) | Release builds are notarized. For a test build you trust, Control-click the app, choose **Open**, then **Open** again |
| Wrong or missing repositories | Install the Relvora GitHub App on those repositories (**Add repositories on GitHub…** in the repository picker) |
| "Your GitHub sign-in expired" | Connect again in **Settings › GitHub**. Cached data stays visible meanwhile |
| A release plan says **Needs reconciliation** | Choose **Check GitHub**. Relvora reads GitHub before anything is created again |

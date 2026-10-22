# Distribution: Developer ID and Notarization

Relvora is distributed as a **notarized Developer ID app**, built by GitHub Actions ([ADR 0011](decisions/0011-distribution-developer-id.md)).
- **How a release works:** you publish a release on GitHub (for example, a draft Relvora created), and the **Release** workflow builds, signs, notarizes, and staples the app. It then attaches `Relvora-<version>.zip` to that release.
- **Before secrets are set up:** the workflow only builds an unsigned test package.

## 1. One-time setup (owner)

You need a paid **Apple Developer Program** membership. You must also be the team's **Account Holder**, because only the Account Holder can create Developer ID certificates. The certificates on this Mac today are Apple Development certificates, which can't sign apps for distribution.

### 1.1 Create a Developer ID Application certificate

The simplest way is in Xcode:
1. Open **Xcode › Settings › Accounts**.
2. Select your Apple ID, then your team, and click **Manage Certificates…**.
3. Click **+** and choose **Developer ID Application**.

Alternatively, on [developer.apple.com](https://developer.apple.com/account/resources/certificates/list):
1. Choose **Certificates › +** and select **Developer ID Application** (G2 Sub-CA).
2. Upload a certificate signing request. Create it in **Keychain Access › Certificate Assistant › Request a Certificate From a Certificate Authority…**, choosing *Saved to disk*.
3. Download the certificate and double-click it to install it.

### 1.2 Export it as a .p12 file

1. Open **Keychain Access › login › My Certificates**.
2. Right-click **Developer ID Application: <your name> (<Team ID>)** and choose **Export…**.
3. Save it as `DeveloperID.p12` with a **strong password**. The export includes the private key.

Keep this file out of the repository. After you've added it to GitHub (step 1.4), delete it or move it to a password manager.

### 1.3 Create a notarization API key

1. In [App Store Connect](https://appstoreconnect.apple.com/access/integrations/api), go to **Users and Access › Integrations › App Store Connect API**, open the **Team Keys** tab, and click **+**.
2. Name it `Relvora notarization` and give it the **Developer** role.
3. Download `AuthKey_<KEYID>.p8`. It can be downloaded **only once**.
4. Note the **Key ID** and the **Issuer ID**, which is shown above the keys list.

### 1.4 Add the GitHub secrets

In the repository, open **Settings › Secrets and variables › Actions › New repository secret**. You can also set them from Terminal in the repository folder. `gh` reads each value from standard input or asks for it, so it never appears in your shell history:

```sh
base64 -i DeveloperID.p12 | gh secret set DEVELOPER_ID_CERTIFICATE_P12
gh secret set DEVELOPER_ID_CERTIFICATE_PASSWORD     # gh asks for the value: paste the .p12 password
gh secret set DEVELOPMENT_TEAM                      # your 10-character Team ID
base64 -i AuthKey_XXXXXXXXXX.p8 | gh secret set NOTARY_API_KEY_P8
gh secret set NOTARY_API_KEY_ID                     # the Key ID
gh secret set NOTARY_API_ISSUER_ID                  # the Issuer ID
```

| Secret | Value |
|---|---|
| `DEVELOPER_ID_CERTIFICATE_P12` | The `.p12` file, base64-encoded |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | Its export password |
| `DEVELOPMENT_TEAM` | Your Team ID |
| `NOTARY_API_KEY_P8` | The `.p8` key file, base64-encoded |
| `NOTARY_API_KEY_ID` | The key's ID |
| `NOTARY_API_ISSUER_ID` | The Issuer ID |

The Team ID is stored as a secret rather than committed, following the rule for local signing settings (ADR 0007).

### 1.5 Check the setup

1. Open **Actions › Release › Run workflow**, enter a version such as `0.0.1`, and run it.
2. The job summary should say "Signed with Developer ID, notarized, and stapled".
3. Download the artifact, unzip it, and run:

   ```sh
   spctl --assess --type execute --verbose=2 Relvora.app   # expect: accepted, source=Notarized Developer ID
   xcrun stapler validate Relvora.app                      # expect: The validate action worked!
   ```

## 2. Releasing a version

1. In Relvora, prepare the release plan and **Create GitHub Draft** (the version is taken from the tag, so use a semantic version such as `1.2.0`).
2. Review and **publish** the draft on GitHub. GitHub then creates the tag.
3. The **Release** workflow starts automatically. After about 10–20 minutes, `Relvora-1.2.0.zip` and its `.sha256` file are attached to the release.
4. In Relvora, **Check Publication** records the release.

For a build that isn't tied to a release, use **Actions › Release › Run workflow**. The result is uploaded as a workflow artifact for 30 days.

### Version numbers

| Release tag | `CFBundleShortVersionString` | `CFBundleVersion` | File name |
|---|---|---|---|
| `v1.2.0` | `1.2.0` | Workflow run number | `Relvora-1.2.0.zip` |
| `v2.0.0-beta.1` | `2.0.0` (the prerelease part is dropped) | Workflow run number | `Relvora-2.0.0-beta.1.zip` |

## 3. What the pipeline checks

`scripts/release/build-release.sh` checks the following, and fails the build if any check fails:
1. It archives the Release configuration as a universal (Apple silicon and Intel) app, with bundle ID `com.erickpea29.Relvora`.
2. It signs the app with **Developer ID Application**, using the hardened runtime and a secure timestamp.
3. It verifies the signature (`codesign --verify --deep --strict`) and that the hardened runtime is enabled.
4. It submits the app with `notarytool` and waits. If the status isn't **Accepted**, it prints Apple's notarization log.
5. It staples the ticket, validates it, and runs a Gatekeeper assessment (`spctl`).
6. It zips the app with `ditto` and writes a SHA-256 checksum.

The script runs locally too, which is useful for testing the pipeline:
- `VERSION=1.2.0 SIGNING=adhoc scripts/release/build-release.sh` builds an unsigned test package.
- `SIGNING=developer-id TEAM_ID=… NOTARY_KEY_PATH=… NOTARY_KEY_ID=… NOTARY_ISSUER_ID=…` builds a signed and notarized app, using the certificate in your login keychain.

Credentials are only ever read from the environment or the temporary CI keychain. They are never printed, and the workflow deletes them when it finishes.

## 4. Limitations

- **Unsigned builds don't open normally.** Builds made without the secrets, including pull-request dry runs, are blocked by Gatekeeper on other Macs. They are for testing only and are never attached to a release.
- **Certificates expire.** A Developer ID certificate is valid for five years. Replace the `DEVELOPER_ID_CERTIFICATE_*` secrets when you renew it. Apps already notarized keep working.
- **No automatic updates.** Users download new versions from GitHub Releases. Their data stays, because the bundle ID and team are unchanged. An updater such as Sparkle is a possible later step.
- **Separate data per build type.** The release build (`com.erickpea29.Relvora`) has its own data container, separate from the `.dev` and `.adhoc` builds (F5). To move data, use **File › Export Backup…** and **Restore from Backup…**.
- **Sign in to GitHub again.** The first launch of a release build needs a new GitHub sign-in, because the Keychain item belongs to each app identity.
- **Private repository.** Release assets of `erickpea29/Release-Manager` are visible only to its collaborators. Public distribution needs a public repository, or another download location.
- **Licence still undecided.** Choose a licence before distributing to others (PRODUCT_SPEC G10).
- **macOS 26 or later.** The app's minimum is macOS 26.0 ([ADR 0003](decisions/0003-minimum-macos-target.md)).
- **No Mac App Store.** It is out of scope for the MVP.

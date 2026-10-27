# GitHub App Setup

Relvora authenticates as a **GitHub App** using the **device flow**. The app ships only the public **client ID**. You never need to generate a client secret or a private key, and none must ever be added to this repository.

## Register the app (one time)

1. Go to GitHub → **Settings → Developer settings → GitHub Apps → New GitHub App**.
2. Fill in:
   - **GitHub App name:** must be globally unique, for example `Relvora` (the owner's app is named Relvora).
   - **Homepage URL:** this repository's URL.
   - **Callback URL:** leave empty. Leave *Request user authorization (OAuth) during installation* unchecked.
   - **Expire user authorization tokens:** keep **checked**. This is GitHub's recommendation, and refresh works without a secret for device-flow tokens.
   - **Enable Device Flow:** **check**.
   - **Webhook → Active:** **uncheck**. There is no server.
3. Set **Repository permissions** (leave everything else at *No access*):

   | Permission | Access |
   |---|---|
   | Checks | Read-only (CI of pull requests and commits, from 0.2.3) |
   | Contents | Read and write (write is used only to create and publish releases, and to merge pull requests you confirm) |
   | Metadata | Read-only (mandatory) |
   | Pull requests | Read-only |

   Set no **Organization** or **Account** permissions.
4. **Where can this GitHub App be installed?**
   - *Only on this account* for personal use and the M00 spike.
   - *Any account* if it must be installed on organizations. A private app can only be installed on its owner account.
   > Set these permissions **before** installing. An app with no repository permissions can only be installed with "No repositories". If you add permissions later, accept them on the installation (*Configure → Review request*).
5. Click **Create GitHub App**, then copy the **Client ID** (it looks like `Iv23li…`). Do not click *Generate a new client secret* or *Generate a private key*.

## Checks permission for CI (0.2.3)

Relvora 0.2.3 shows the CI of pull requests and commits ([ADR 0020](decisions/0020-pull-requests-and-ci.md)). That needs **Checks: Read-only**, which an app registered before 0.2.3 doesn't have. Until it's added, Relvora says so where pull requests are listed, and doesn't offer to merge.

1. On GitHub: **Settings → Developer settings → GitHub Apps → Relvora → Permissions & events**.
2. Under **Repository permissions**, set **Checks** to **Read-only**, then **Save changes**.
3. Accept it on each installation: **Settings → Applications → Installed GitHub Apps → Relvora → Configure**, then **Review request → Accept new permissions**. Organization installations are accepted by an owner.

Merging uses **Contents: Read and write**, which Relvora already has. A pull request that changes files in `.github/workflows` may also need **Workflows: Read and write**. Without it, GitHub refuses that merge, Relvora shows GitHub's reason, and you merge it on GitHub instead.

## Install the app on repositories

User tokens can only reach repositories where the app is installed *and* you have access.

1. On the app's page, click **Install App**, then choose your account.
2. Select **Only select repositories** and pick the repositories to manage.
3. In organizations, owners can install it. Repository admins can also install it, because the app requests no organization or administration permissions. Other members can only request installation.

## M00 live validation

Use a throwaway repository with at least two tags for the write probe. It creates a draft release and then deletes it.

```sh
cd spikes/M00/SpikeKit
GITHUB_APP_CLIENT_ID=<client id> swift run gh-auth-spike validate --repo <owner>/<repo>
GITHUB_APP_CLIENT_ID=<client id> swift run gh-auth-spike validate --repo <owner>/<test-repo> --write
```

## Connecting in Relvora

1. **Settings › GitHub › Connect GitHub…** (or a project's **GitHub** tab).
2. **Copy Code and Open GitHub**, paste the code, and approve. Only approve codes you started in Relvora.
3. In a project's **GitHub** tab: **Connect Repository…**, then choose a repository. Only repositories selected in the app's installation appear; use **Add repositories on GitHub…** to add more.

## Disconnecting

The app can delete its stored tokens, but it cannot revoke them on GitHub without the client secret. To revoke fully, go to **Settings → Applications → Authorized GitHub Apps → Revoke**.

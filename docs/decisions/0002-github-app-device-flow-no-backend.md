# 0002 — GitHub App with device flow; no backend

- **Status:** Accepted (device flow and secretless refresh validated live on 2026-10-21, M00 §2.5)
- **Date:** 2026-10-19

## Context

The app must never embed a client secret or private key. The plan allows a minimal Cloudflare Worker only if the spike proves a confidential exchange is unavoidable.

## Decision

- Register a **GitHub App** with **Enable Device Flow** and **token expiration on**.
- Ship only the client ID.
- Use `POST /login/device/code` + `POST /login/oauth/access_token` for login.
- Use `grant_type=refresh_token` without `client_secret` (documented as allowed for device-flow tokens).
- Store the access token, refresh token, and expiry together in Keychain in one write; serialize refreshes, because refresh tokens rotate.
- When the refresh token expires or a refresh fails with `bad_refresh_token`, re-run the device flow.
- **Disconnect** deletes local credentials and links to GitHub's *Authorized GitHub Apps* page. Server-side revocation needs the secret and is not attempted.
- Discover repositories via `GET /user/installations` and `/user/installations/{id}/repositories`. Send users to `https://github.com/apps/<slug>/installations/new` to add repositories.
- **No backend, no Cloudflare** for the MVP.

## Consequences

- Phishing risk is inherent to the device flow. Start it only on explicit user action, display the code in-app, and open `verification_uri` from the app.
- "All repositories the user can access" becomes "repositories where the app is installed", and the UI must explain this.
- Permissions: Metadata read, Contents write, Pull requests read. Workflows write is excluded; a release whose target commit changes `.github/workflows/*` fails with a clear message.

## Revisit if

The live run shows refresh requires a secret. Fallback: keep expiration on and re-authorize every 8 hours, or opt out of expiration. Do not add a server.

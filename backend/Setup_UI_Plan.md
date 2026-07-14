# Native First-Run Setup UI Plan

Status: implementation plan  
Last updated: 2026-07-14  
Related plans: [`Product_Plan.md`](./Product_Plan.md), [`Tasks.md`](./Tasks.md)

## 1. Requirement interpretation

The native app needs one setup experience that can be opened automatically on a new installation or manually from Settings. It lets the user choose between:

- **sttapp Hosted**: authenticate in the system browser, receive sttapp backend access/refresh credentials, subscribe when necessary, and select an enabled hosted model.
- **Manual provider**: use the existing API key, OpenAI-compatible base URL, connection test, and model selection controls.

The statement that setup should open Settings to configure an API key, backend, and model is interpreted as the **manual provider** path. Hosted mode must not ask the user for or display an API key or editable backend URL. Both paths live inside the existing Settings window and finish on the same permission/shortcut readiness flow.

## 2. Design goals

- Make the hosted/manual choice understandable before any audio can be recorded.
- Preserve the current manual setup without forcing existing users to create an account.
- Keep hosted credentials invisible and distinct from manual API keys.
- Reuse the existing 520×720 Settings window, Material theme, permission UI, model loading, and secure storage.
- Allow users to rerun setup without deleting either provider's saved credentials.
- Make every asynchronous step recoverable: browser sign-in, token exchange, subscription activation, model loading, connection testing, and OS permissions.
- Keep one clear primary action on each setup page.
- Never switch the audio destination silently.

## 3. Existing native constraints

- Settings currently opens at 520×720, is resizable from 420×480 to 900×900, and uses a single scrolling column.
- An incomplete manual `TranscriptionConfig` currently opens Settings automatically and prevents the window from closing.
- The current settings page already owns API key visibility, base URL, model discovery/manual model, connection testing, shortcut choice, update status, and macOS permissions.
- The recorder window is intentionally only 400×120 and is not suitable for onboarding.
- Existing installations may already have a valid manual provider configuration in native secure storage.

## 4. Setup entry and migration rules

### New installation

Open Settings in `setup` mode when no setup completion record exists. The setup window must appear before hotkeys can start a transcription.

### Existing installation upgrade

- If the existing API key/base URL/model configuration is valid, migrate it to `providerMode = manual`, mark the current setup version complete, and do not interrupt the user with first-run setup.
- If legacy configuration is absent or incomplete, open the new setup flow.
- Never send an existing manual-provider API key to the sttapp backend during migration.

### Settings entry

Add a **Transcription provider** section near the top of Settings with the current mode, account/endpoint summary, model, and a **Run setup again** secondary action. Rerunning setup starts at the provider chooser and preserves hosted and manual credentials until the user explicitly signs out or clears a manual field.

### Forced re-entry

Open the relevant setup page when:

- no provider mode is complete;
- hosted refresh credentials are permanently invalid and reauthentication is required;
- hosted mode has no selectable model;
- manual configuration becomes invalid;
- a required OS permission is missing.

A payment hold or canceled hosted subscription opens the hosted account section with an action to update billing or resubscribe; it does not reset setup completion.

## 5. Navigation model

Use one Settings shell with two modes:

- `setup`: focused, step-based content with Back/Continue and no unrelated update/version content in the main flow;
- `settings`: the full post-setup settings page with provider, permissions, shortcuts, updates, and setup re-entry.

The setup flow is deliberately short:

```text
Start
  |
  v
Choose provider
  |-----------------------------|
  v                             v
Hosted account               Manual provider
  |                             |
  | sign in / subscribe         | API key / URL / test / model
  | model                       |
  |-----------------------------|
                |
                v
       Permissions & shortcut
                |
                v
              Ready
```

Use an explicit step label such as `Step 1 of 3`, but do not render a large multi-step navigation rail in the compact window. Back is available until the final page. The selected provider is not committed as active until its page validates successfully.

## 6. Setup shell

### Window and layout

- Reuse `_showSettingsWindow()` sizing and title-bar behavior.
- Page background uses the existing Material surface; use whitespace and dividers before adding cards.
- Use 24px outer padding at normal width and 16px at the 420px minimum width.
- Keep content in one scrollable column with a sticky or bottom-aligned action area when possible.
- Use the existing blue Material color scheme rather than introducing another accent.
- Use one filled primary action per page; Back, cancel, test, portal, and sign-out are secondary/tonal/text actions.
- Keep option rows and controls at least 44px high with visible keyboard focus.

### Header

In setup mode:

- Window title: **Set up sttapp**.
- Leading Back button on steps after provider choice.
- Close is disabled until a valid provider and required permissions exist. A separate **Quit sttapp** text action may be offered on the first page so users are not trapped.
- Show a small step label and a concise page heading; do not show version/update status above setup content.

In ordinary Settings mode:

- Keep the current **Settings** title and close behavior.
- Provider status and **Run setup again** appear as settings content, not as a blocking wizard.

## 7. Screen 1 — Choose a transcription provider

Purpose: explain the data destination and responsibility difference before requesting credentials or payment.

```text
+--------------------------------------------------+
| Set up sttapp                              Close |
| Step 1 of 3                                      |
|                                                  |
| How would you like to transcribe?                |
| Choose where sttapp sends recorded audio.        |
|                                                  |
| [cloud icon] sttapp Hosted                       |
| Sign in and let sttapp manage the transcription |
| service. $1/month with $0.50 usage included.     |
|                                           ( )    |
| ------------------------------------------------ |
| [key icon] Manual provider                       |
| Use your own OpenAI-compatible API key, endpoint,|
| and model.                                 ( )   |
|                                                  |
| Audio is sent only to the provider you choose.   |
|                                                  |
|                                      [Continue]  |
+--------------------------------------------------+
```

Interaction rules:

- Entire option rows are selectable and expose a radio semantic; do not use two competing filled buttons.
- Default to no selection for a genuinely new installation. When rerunning setup, preselect the active mode but do not advance automatically.
- Hosted pricing copy links to the full terms/pricing page and does not promise fixed transcription hours.
- Manual copy explicitly says the user pays/manages that provider separately.
- Continue remains disabled until a choice exists.

## 8. Screen 2A — sttapp Hosted

This screen is state-driven rather than a long form. The app never displays or asks for the backend token.

### Signed out

```text
| sttapp Hosted                                    |
| Sign in securely in your browser.                |
|                                                  |
| Your browser handles Clerk authentication.       |
| sttapp returns a one-time code to this app and   |
| the backend issues the access used for requests. |
|                                                  |
|                                [Sign in securely]|
```

- **Sign in securely** is the single primary action.
- Opening the browser changes the screen to a waiting state with progress, **Open browser again**, and **Cancel sign-in** secondary actions.
- The callback contains only a short-lived one-time authorization code. The app exchanges it with the backend using the PKCE verifier.
- The backend returns a short-lived access token and rotating refresh token. Both are stored in native secret storage; only non-sensitive account information appears in UI.

### Signed in, subscription required

Show account email/name, plan summary, included usage, overage explanation, and links to terms/privacy. The single primary action is **Subscribe for $1/month**. Checkout opens in the system browser. While waiting for the signed Dodo webhook, show **Waiting for payment confirmation** with **Refresh status** as a secondary action.

### Active subscription

Show a compact success status, current period/canceling state, and hosted model dropdown populated from `/v1/models`. **Continue** becomes the single primary action once a model is selected. **Usage & billing** and **Sign out** are secondary actions.

### On hold or canceled

- `on_hold` / `past_due`: show the reason and **Update payment method** as the primary recovery action.
- `canceled` / `expired`: show **Resubscribe** as primary.
- A visible **Use a manual provider instead** secondary action returns to provider choice.

### Token behavior

- The app sends `Authorization: Bearer <sttapp_access_token>` to hosted `/v1/*` routes.
- Refresh automatically before expiry and once after a 401 that specifically indicates token expiry.
- Refresh tokens rotate on every successful refresh. Reuse detection revokes the backend session and requires sign-in again.
- If refresh fails due to network, retain credentials and offer Retry; if the backend reports revoked/expired credentials, clear them and show Sign in.
- Never use a backend token in manual mode and never put one in the current API-key text field.

## 9. Screen 2B — Manual provider

This path reuses the existing Settings controls in a focused provider page:

```text
| Manual provider                                  |
| Enter an OpenAI-compatible transcription API.    |
|                                                  |
| API key                           [show/hide]     |
| [••••••••••••••••••••••••••••••••••••••]       |
|                                                  |
| Base URL                                         |
| [https://api.example.com/v1             ]        |
|                                                  |
| Model                                            |
| [Select after testing                     v]      |
|                                                  |
| [Test connection]                    [Continue]  |
```

Rules:

- Preserve the current secure-storage keys and legacy migration.
- API key is obscured by default. Base URL remains editable.
- **Test connection** is secondary; it calls `/models`, reports success/failure inline, and populates the model dropdown.
- A manual model option remains available when `/models` is unsupported or the stored model is not returned.
- Continue validates API key, URL, and model and saves manual configuration.
- Do not send any manual credential to Clerk, Dodo, or the sttapp backend.
- A successful manual connection requires no hosted account, subscription, checkout, or backend token.

## 10. Screen 3 — Permissions and shortcut

Reuse the existing permission and shortcut components after either provider path:

- On macOS, request Microphone and Accessibility with individual status/action rows.
- On every platform, show the selected normal/plain shortcut summary and allow supported shortcut changes.
- Register/test shortcuts before allowing Finish.
- Keep provider setup saved if the user leaves to approve OS permissions and restore this page when the app regains focus.
- **Finish setup** is enabled only when the chosen provider is valid and required permissions/shortcut registration are ready.

If permissions do not apply or are already granted, this page still provides a short readiness summary rather than flashing past unexpectedly.

## 11. Ready screen and completion

Show:

- selected provider;
- selected model;
- shortcut labels;
- a one-sentence instruction: **Press F8 to record and paste a transcription.** (substitute the configured key);
- **Finish** as the single primary action.

Finish writes a versioned setup-completion record, initializes input services, refreshes the tray menu, and hides the Settings window. Setup completion is a local UI state; it does not override hosted entitlement checks or manual config validation.

## 12. Post-setup Settings information architecture

Order Settings content by frequency and actionability:

1. **Transcription provider**
   - Hosted: account, subscription status, model, Usage & billing, Sign out, Run setup again.
   - Manual: masked credential status, base URL, model, Test connection, Edit, Run setup again.
2. **Permissions** when applicable.
3. **Keyboard shortcut**.
4. **Updates and version information**.

Do not render manual API fields and hosted account/billing controls at the same time. This reduces the chance of confusing the active audio destination.

## 13. State and persistence model

Add local, versioned state separate from `TranscriptionConfig`:

```text
providerMode: hosted | manual | unset
setupVersionCompleted: integer | null
setupDraftStep: choose | hosted | manual | permissions | ready
hostedModel: string | null
manualConfig: existing TranscriptionConfig
```

Hosted secret storage holds:

```text
hostedAccessToken
hostedAccessTokenExpiresAt
hostedRefreshToken
hostedSessionId
```

Persist only after a meaningful transition. Never store PKCE verifier/state after the transaction completes or expires. Draft setup state must not mark an invalid provider active.

Backend auth persistence holds a hashed refresh-token family and session metadata; raw refresh tokens are returned once and never stored server-side in plaintext.

## 14. Backend desktop-token handoff

Recommended flow:

1. App generates PKCE verifier/challenge and random state.
2. App calls `POST /v1/auth/desktop/start` with the challenge and loopback redirect details.
3. Backend creates a short-lived login transaction and returns an allowlisted sttapp HTTPS authorization URL.
4. App opens that URL in the system browser.
5. The backend web route uses Clerk to sign in the user and bind the verified Clerk subject to the transaction.
6. Backend redirects to the loopback URI with a one-time authorization code and state, never an access or refresh token.
7. App validates state and calls `POST /v1/auth/desktop/exchange` with the code, verifier, and transaction identifier.
8. Backend atomically consumes the code, provisions the local account, creates a backend session, and returns an access token plus rotating refresh token.
9. App uses `POST /v1/auth/refresh` to rotate credentials and `POST /v1/auth/logout` to revoke the session.

The token contract must define issuer, audience, subject, session ID, token ID, expiry, signing-key ID, clock skew, refresh-family lifetime, inactivity timeout, reuse detection, and key rotation. A short access lifetime limits revocation delay; the exact values are deployment configuration and require a recorded security decision.

## 15. Error and recovery states

Every failure page keeps the user's safe next action visible:

| Failure | UI behavior |
| --- | --- |
| Browser cannot open | Show Copy sign-in link and Retry |
| Sign-in canceled/timed out | Return to signed-out hosted state |
| Callback state mismatch | Reject it, clear transaction, restart sign-in |
| One-time code used/expired | Restart sign-in; never retry exchange blindly |
| Token refresh network failure | Keep credentials, show Retry/offline error |
| Refresh revoked/reused/expired | Clear hosted session and require Sign in |
| Checkout canceled | Stay signed in with Subscribe action |
| Dodo webhook delayed | Show waiting state and bounded Refresh status |
| Hosted model removed | Require another model before transcription |
| Manual `/models` unsupported | Offer Manual model entry |
| Manual test fails | Preserve fields and show inline safe error |
| Permission denied | Link to OS settings; keep setup open |
| Shortcut unavailable | Show failed combination and Retry/change shortcut |

Errors include a request ID where available but never show raw provider responses, tokens, secrets, or transcript content.

## 16. Accessibility and interaction requirements

- Full keyboard navigation with predictable focus order and Enter/Space activation.
- Move focus to the page heading after a setup step change.
- Use radio, button, progress, status, text-field, and select semantics rather than gesture-only containers.
- Announce async status changes such as browser waiting, connection success, model loading, and payment activation to assistive technologies.
- Do not use color as the only indicator of selected, success, warning, or error state.
- Respect platform text scaling; the 420px minimum width must remain usable at 200% text scale with scrolling and no clipped actions.
- Keep one filled primary action per page and preserve visible focus indication.
- Do not animate step transitions when reduced motion is enabled.

## 17. Analytics and privacy

Optional product analytics may record only setup step, provider-mode choice, completion/failure category, duration, and platform. Do not record API keys, URLs, model text typed manually, account email, tokens, transcripts, audio, or browser callback parameters. Analytics must follow the product's consent/privacy policy.

## 18. UI acceptance criteria

- A fresh install cannot record until hosted or manual setup and required permissions are complete.
- A valid existing manual installation upgrades without seeing setup and remains in manual mode.
- Setup can be launched again from Settings without deleting stored credentials.
- Hosted mode never displays an API-key field or stores Clerk credentials as the bearer token.
- The backend, not Clerk or the client, issues the token used on hosted API requests.
- Access-token expiry refreshes transparently; refresh reuse/revocation requires sign-in.
- Manual mode behaves like the current app and sends credentials only to the configured endpoint.
- Switching modes is explicit, confirmed, and never silently reroutes audio.
- Hosted/manual setup, callback recovery, payment waiting, model loading, permissions, shortcut failure, restart, and migration are widget/service tested.
- The setup flow is usable at 420×480, 520×720, 900×900, keyboard-only, and 200% text scale on Linux, macOS, and Windows.

# logto-swift — `native-browser` fork

This is a soft fork of [logto-io/swift](https://github.com/logto-io/swift)
that replaces the upstream embedded-web-view sign-in presenter with
`ASWebAuthenticationSession`. The rest of the SDK (PKCE, token exchange,
refresh, storage) is unchanged. This file documents what the fork
actually does, why each change exists, and how to keep it in sync with
upstream.

> Canonical authority for the product-side contract lives in
> [`LOGTO-FORK.md`](https://github.com/muratpisat/swift-webrtc-hdr/blob/main/LOGTO-FORK.md)
> in the consuming Calido app. This README is the engineering-side
> companion for people working inside this repo.

## 1. Why the fork exists

Upstream Logto presents the OIDC authorization page inside a `WKWebView`.
Embedded web views do not share cookies, Keychain autofill, or Passkey
state with Safari, so every sign-in looks like a fresh login to
Google/Apple/etc. and users are forced to re-authenticate on every
device.

`ASWebAuthenticationSession` is Apple's system-browser handoff API. It
shares Safari cookies + Keychain, supports Passkeys, and shows the same
URL bar users already trust. The fork is the minimum change needed to
move sign-in onto that API without rewriting the rest of the SDK.

See `LOGTO-FORK.md §1–2` in the Calido repo for the full product-side
rationale and branch policy.

## 2. Branch layout

| Branch | Role |
|--------|------|
| `master` | Mirrors `logto-io/swift` master. Fast-forward only. Never commit our patches here. |
| `native-browser` | Permanent working branch carrying the presenter swap. Default branch on GitHub. |

Rebase `native-browser` onto upstream, never merge. Force-push with
`--force-with-lease`. Tagged releases (`native-browser-1`, `-2`, …) pin
an (upstream commit → fork commit) mapping.

## 3. Patch surface

The fork touches **7 files** plus test swaps. Every change is either:

- **Presenter-swap**: replacing the WKWebView stack with `ASWebAuthenticationSession`.
- **Fork-only plumbing**: exposing the caller's `UIWindowScene` so iPad
  multi-scene setups can anchor correctly.
- **Error surface**: distinguishing genuine "user cancelled" from
  authentication failures, which the web-view path could not.

### 3.1 `Sources/LogtoClient/LogtoAuthSession/LogtoAuthSession.swift`

**What changed.**

- Added `weak var preferredPresentationScene: UIWindowScene?` (iOS only).
  The caller stores the scene that hosts the view controller starting
  sign-in; the presenter uses it to anchor the system sheet.
- The `FinishHandler` callback now receives `(URL?, Error?)` instead of
  `URL?`. Upstream could only report "finished with URL or nil" — the
  system sheet distinguishes dismissal, network error, and real auth
  failure, and we need that distinction to surface
  `userCancelled` vs `authFailed` up the stack.
- Added `isUserCancellation(_:)`. Maps
  `ASWebAuthenticationSessionError.canceledLogin` and our own
  `LogtoWebViewAuthViewError.noPresentationAnchor` to the
  `Errors.SignIn.userCancelled` case so the app can skip noisy error
  UI when the user just backs out of the sheet.
- The strong-capture comment on the `DispatchQueue.main.async` hand-off
  exists because `LogtoWebViewAuthSession` is no longer retained by a
  presented view controller — `ASWebAuthenticationSession` is the only
  thing holding it alive via its completion closure, and the main-queue
  async block must keep the session reachable until `start()` actually
  fires on the UI thread.

**Why.** The upstream presenter was a full `UIViewController` pushed on
the caller's navigation stack, so the view hierarchy itself retained the
session. `ASWebAuthenticationSession` is a plain class with no UI
ownership, so retention is now the call-site's responsibility. Passing
the scene through this layer keeps PKCE/state/nonce generation exactly
where upstream puts it — the fork does not touch any cryptographic code.

### 3.2 `Sources/LogtoClient/LogtoAuthSession/LogtoWebViewAuthSession.swift`

**What changed.** Rewritten. The file used to host start/cancel glue for
the WKWebView view controller; it now owns an
`ASWebAuthenticationSession` directly.

Key points:

- `start()` constructs the session, installs
  `LogtoWebViewAuthPresenter` as the presentation context provider, and
  calls `session.start()` on the main queue.
- `prefersEphemeralWebBrowserSession = false` is explicit (not relying
  on the default). Ephemeral mode would defeat the whole point of the
  fork — the shared Safari cookie jar is the user-visible win.
- `handleCompletion(callbackURL:error:)` is exposed as `internal`
  (`@testable`) rather than `private` so redirect-validation tests can
  exercise it without spinning up a real `ASWebAuthenticationSession`.
- Strict redirect validation: the callback is accepted only if its
  scheme (case-insensitive), host, and path match the registered
  `redirectUri`. Upstream trusted whatever the web view loaded because
  the navigation delegate gated URL handling; the system sheet will
  return *any* URL on the registered scheme (including arbitrary deep
  links), so we must re-check the contract here. Dropping this check
  would let a crafted `io.logto://callback/evil?code=…` be accepted
  as a sign-in callback.
- `didFinish(url:error:)` is idempotent (`isFinished` guard). The system
  sheet can fire its completion multiple times in edge cases (e.g.
  cancel during launch), and double-firing upstream's `onFinish` would
  resume the continuation twice and crash.
- `socialPlugins` is retained on the initializer for source
  compatibility with upstream callers, but is no longer invoked. The
  upstream JS bridge that dispatched native plugin connectors lived in
  the `WKWebView` script message handlers (see §3.3 deleted files).
  Safari runs the auth page out-of-process, so the bridge is
  physically unreachable from system-browser mode. Calido does not use
  WeChat/Alipay, and the social-callback contract — Logto redirects to
  a scheme the host app claims, host app launches the native SDK, SDK
  posts the result back to Logto — still works through the normal
  redirect path without the bridge. See `LOGTO-FORK.md §4` and §5.4 for
  the Android analog of this argument.

**Why.** Upstream's `WKWebView`-based session conflated *navigation*
(redirect validation, URL loading) with *presentation* (view controller
lifecycle, cookie cleanup). `ASWebAuthenticationSession` owns
presentation; our responsibility shrinks to (a) starting/cancelling the
session, (b) validating the redirect, (c) forwarding the result. The
file's shape reflects that narrower contract.

### 3.3 `Sources/LogtoClient/LogtoAuthSession/LogtoWebViewAuthViewController.swift`

**What changed.** The WKWebView-backed `UIViewController` was deleted
and replaced with `LogtoWebViewAuthPresenter` — a tiny `NSObject` that
conforms to `ASWebAuthenticationPresentationContextProviding`.

The presenter contains multi-scene anchor logic, which is the trickiest
correctness requirement of the fork:

1. If the caller passed a `preferredScene`, look for a window there
   first. On iPad with Stage Manager / Split View, more than one
   `UIWindowScene` is `.foregroundActive` simultaneously. Picking the
   first match anchors the sheet to the wrong window and, in some
   configurations, crashes with a "no window to present from"
   assertion.
2. Otherwise scan `UIApplication.shared.connectedScenes` for
   `.foregroundActive` scenes and pick a key window there.
3. If no foreground-active scene exists (background launch, extension,
   app resuming mid-animation), return `nil`. `LogtoWebViewAuthSession`
   maps that to `LogtoWebViewAuthViewError.noPresentationAnchor`,
   which `LogtoAuthSession.isUserCancellation` treats as a cancellation.
   We do not fall back to `.foregroundInactive` scenes — the sheet
   would attach to a window transitioning off-screen and present in
   the wrong place. Failing cleanly is better than presenting wrong.

Within a chosen scene, preference order is
`keyWindow` (iOS 15+) → any window with `isKeyWindow == true` → first
window. This covers the couple of windows frameworks like SwiftUI/Scene
delegates create before the key window is set.

**Why.** The upstream view controller's 108 lines existed entirely to
host the `WKWebView` and clean up its cookies. Once the web view is
gone, none of that code has a home. The presenter is 60 lines, all of
which are scene-anchor logic that upstream never had to solve because
the view controller was pushed onto a navigation stack the caller
already owned.

The file keeps its original name to minimize diff noise against
upstream during rebases. A rename would force the next upstream bump to
resolve a delete+add merge every time.

### 3.4 Deleted files

- `Sources/LogtoClient/LogtoAuthSession/LogtoWebViewAuthViewController+WKNavigationDelegate.swift`
- `Sources/LogtoClient/LogtoAuthSession/LogtoWebViewAuthViewController+WKScriptMessageHandler.swift`
- `Tests/LogtoClientTests/LogtoAuthSession/LogtoWebViewAuthViewControllerTest.swift`

The two extension files hosted `WKWebView`'s navigation and script
message callbacks: URL interception, social-plugin JS bridge, cookie
cleanup. None of that is reachable once the web view is gone. Deleting
them is the honest way to document "this code no longer runs."

The WKWebView tests exercised the deleted code paths and would not
compile against the new surface. They are replaced by
`LogtoWebViewAuthSessionTests.swift` (see §3.8).

### 3.5 `Sources/LogtoClient/LogtoAuthSession/LogtoWebViewAuthViewError.swift`

Added `noPresentationAnchor` case. The upstream error enum had only
`webAuthFailed` and `unableToConstructCallbackUri` because the web view
always had a view hierarchy to attach to — presentation never failed
for structural reasons. `ASWebAuthenticationSession` requires a live
scene/window; "no scene is active" is a first-class failure mode in
this world and the error type needs to name it so we can classify it
as a cancellation rather than a generic failure.

### 3.6 `Sources/LogtoClient/LogtoClient/LogtoClient+SignIn.swift`

**What changed.**

- Split the 55-line `signInWithBrowser` into two pieces: a platform-gated
  generic entry point that creates the `LogtoAuthSession`, and a shared
  `completeSignIn(session:oidcConfig:)` helper that runs `session.start()`,
  verifies the ID token, and writes tokens into storage. The split exists
  only so the iOS path can set `session.preferredPresentationScene`
  between those two phases without duplicating the persistence block.
- Added a `presentationScene: UIWindowScene?` parameter (iOS only) on
  both the internal generic helper and the public
  `signInWithBrowser(redirectUri:...)` entry point. Default is `nil`,
  preserving the upstream call-site contract — consumers that do not
  care about iPad multi-scene get the global-scan fallback.

**Why.** Without this plumbing, `preferredPresentationScene` was
present on `LogtoAuthSession` but physically unsettable from outside
the module (it is `internal`). The property would have been dead code,
and iPad Stage Manager / Split View callers would silently get the
wrong window. The API surface change is backwards-compatible: a default
of `nil` means every existing caller compiles and behaves the same as
before.

### 3.7 `Sources/LogtoClient/Types/LogtoClientErrorTypes.swift`

Added `userCancelled` case on the public `SignIn` enum.

**Why.** `ASWebAuthenticationSession` distinguishes "user dismissed the
sheet" (`.canceledLogin`) from "authentication failed." Upstream
conflated both into `authFailed` because the web view reported
`viewDidDisappear` for every termination, with no signal of intent.
Calling apps need the distinction so they can suppress error toasts /
retry loops when the user *chose* to cancel.

**Compat note.** This is a source-compat break for any consumer with an
exhaustive `switch` over `LogtoClientErrorTypes.SignIn` without
`@unknown default`. Fork consumers (Calido) do not have such switches.
If upstream ever adds a similar case under a different spelling we will
rename to match during rebase to avoid a second break.

### 3.8 `Tests/LogtoClientTests/LogtoAuthSession/LogtoWebViewAuthSessionTests.swift`

Replaces `LogtoWebViewAuthViewControllerTest.swift`. Covers:

- `handleCompletion` redirect validation: matching URI accepted,
  case-insensitive scheme, mismatched host rejected, mismatched path
  rejected, nil URL forwards the error.
- `didFinish` idempotency: second call is a no-op.
- `start()` input validation: empty scheme fails fast with
  `unableToConstructCallbackUri`.

No test spins up a real `ASWebAuthenticationSession` — the system sheet
cannot present headlessly in CI. Everything that runs in the tests is
the logic we added; the presenter and anchor-resolution paths are
exercised manually on-device per `LOGTO-FORK.md §8`.

## 4. Working on the fork

### 4.1 Local setup

```bash
cd ~/Documents/Developer/github
git clone git@github.com:mpisat/logto-swift.git
cd logto-swift
git remote add upstream https://github.com/logto-io/swift.git
git fetch upstream
git checkout native-browser
```

### 4.2 Running tests

```bash
xcodebuild -scheme LogtoSDK-Package \
  -destination 'platform=iOS Simulator,OS=26.3.1,name=iPhone 17 Pro' \
  -only-testing:LogtoClientTests/LogtoWebViewAuthSessionTests test

xcodebuild -scheme LogtoSDK-Package \
  -destination 'platform=iOS Simulator,OS=26.3.1,name=iPhone 17 Pro' \
  -only-testing:LogtoClientTests/LogtoAuthSessionTests test
```

Both suites must pass before pushing. On-device sign-in smoke test
(per `LOGTO-FORK.md §8`) is mandatory before tagging a release.

### 4.3 Rebasing onto upstream

```bash
git fetch upstream
git log --oneline upstream/master ^master        # inspect upstream drift
git checkout native-browser
git rebase upstream/master
# resolve conflicts — they almost always live outside the 7 files above
xcodebuild ... test                              # full test suite
git push --force-with-lease origin native-browser
git tag native-browser-N && git push --tags
```

Record the mapping in `LOGTO-FORK.md §7.1` (consuming-app repo) in the
same PR that bumps the SPM pin. Skipping the tag makes future
rollback-bisect require a diff archaeology session.

## 5. Invariants to preserve

Anything that breaks these is a rebase-blocking regression:

1. **PKCE + `state` + `nonce` stay upstream.** The presenter change must
   not move `code_verifier`, `state`, or `nonce` generation. They live in
   `LogtoAuthSession.init` for a reason — they are deterministic per
   sign-in attempt and must be compared exactly on callback.
2. **Strict redirect match.** `handleCompletion` must reject any
   callback URL whose scheme / host / path do not match the registered
   `redirectUri`. Regressing this turns our scheme into an open
   redirect for anyone on the device.
3. **Shared cookies.** `prefersEphemeralWebBrowserSession` must stay
   `false`. Setting it to `true` gives back an incognito-equivalent
   session and defeats the fork's purpose.
4. **Active-scene-only anchoring.** Do not restore the
   `.foregroundInactive` fallback. Failing is correct when no active
   scene exists; force-presenting is not.
5. **No secrets in logs.** Never log the authorization code, tokens,
   `state`, or `nonce`. This has always been upstream policy and the
   fork must not add instrumentation that weakens it.

## 5.1 Account switching after sign-out — handled by the consumer

`LogtoClient.signOut()` (upstream) clears tokens from memory / Keychain
and revokes the refresh token against the OIDC provider. It does **not**
hit Logto's `end_session_endpoint`. In the original WKWebView world that
was fine: the embedded web view's cookie jar vanished with the view
controller, so there was no residual session to clean up.

With the system-browser fork that invariant flips. `ASWebAuthenticationSession`
shares Safari's cookie jar (by design — see §1), so Logto's session
cookie and the upstream social-provider cookie both survive an app-side
`signOut()`. The next `signInWithBrowser` sees the still-valid Logto
session cookie and silently re-authenticates with the last-used
provider. The user-visible symptom is "I tap sign-in and I'm already
signed in as the same account; I can't switch to a different Google
account without clearing Safari cookies manually."

The fork deliberately does **not** fix this itself. Two reasons:

1. **Scope discipline.** The fork's diff is scoped to the sign-in
   presenter (§3). Adding an end_session flow to `signOut` means
   pulling in OIDC config fetch, another `ASWebAuthenticationSession`
   presenter, scene-anchor logic duplication, and admin-side config
   (`post_logout_redirect_uri`). All of that changes the upstream
   contract and makes rebases harder.
2. **Consumer-owned UX.** When and how to present the logout sheet is
   app-level. Some apps may want it on every sign-out; others only when
   the user explicitly taps "Switch account." Encoding either policy in
   the SDK is wrong.

**Recommended consumer pattern** (what Calido does — see
`LOGTO-FORK.md §8.1` in the consuming app):

```swift
// Pseudocode — full implementation in MeetHDR/Services/CalidoAuth.swift
let idTokenHint = logtoClient.idToken           // capture BEFORE clearing
_ = await logtoClient.signOut()                 // revoke refresh token + clear local

if let idTokenHint {
    var components = URLComponents(string: "\(endpoint)/oidc/session/end")!
    components.queryItems = [
        URLQueryItem(name: "id_token_hint", value: idTokenHint),
        URLQueryItem(name: "client_id", value: appId),
        URLQueryItem(name: "post_logout_redirect_uri", value: "io.logto://callback"),
    ]
    let session = ASWebAuthenticationSession(
        url: components.url!,
        callbackURLScheme: "io.logto"
    ) { _, _ in }
    session.prefersEphemeralWebBrowserSession = false   // must share cookies
    session.presentationContextProvider = anchorProvider
    _ = session.start()
    try? await Task.sleep(nanoseconds: 2_000_000_000)   // safety timeout
    session.cancel()                                     // no-op if completed
}
```

Notes for anyone copying this pattern:

- **Do not substitute `prompt=login` on the authorize request.** It was
  tried as an alternative (force Logto to reprompt even when a session
  cookie exists) and it produced post-sign-in session instability in
  Calido (immediate "session expired" after successful Gmail sign-in,
  broken WebSocket reconnects). The clean separation — sign-in unchanged,
  sign-out augmented — is the one that held up on device.
- **Capture `id_token` before `signOut()`.** The SDK clears it
  synchronously; reading it afterwards returns `nil` and Logto rejects
  end_session without `id_token_hint`.
- **`prefersEphemeralWebBrowserSession = false` is required.** Ephemeral
  mode invalidates a cookie in its own private jar, which nothing else
  can see. The whole point is the *shared* jar.
- **2 s timeout.** Logto invalidates the session server-side the moment
  the end_session GET lands, regardless of whether it can redirect back
  to `post_logout_redirect_uri`. Cancelling the browser session after
  the request is in flight is therefore safe. If the admin has
  registered the redirect URI, Logto finishes in well under 2 s and the
  timeout never fires.

If upstream ever adds a built-in RP-initiated logout helper (they have
`LogtoCore.generateSignOutUri` but no presenter glue), the fork should
adopt it and this section should shrink to a pointer.

## 6. References

- `LOGTO-FORK.md` (Calido repo): product-side contract, test
  checklist, rollback mapping table.
- Upstream docs: `README.md` in this repo (unchanged).
- `ASWebAuthenticationSession` docs: [Apple Developer — AuthenticationServices](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession).

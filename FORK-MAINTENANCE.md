# Calido Swift SDK fork maintenance

## Release and rollback bases

- Candidate branch: `codex/native-browser-v2` in `mpisat/logto-swift`.
- Official stable base: Swift SDK 2.0.0, `cce994325e7b898356cb66e96eae5790b7145ade`.
- Previous consumed fork and rollback: `native-browser`, `b048969fea25f81c213322a368ba67dc4ab36fb5`.
- Dependencies remain JOSESwift 3.0.0 (`c2664a902e75c0426a1d43132bd4babc6fd173d3`) and KeychainAccess 4.2.2 (`84e546727d66f1adc5439debad16270d0fdd04e7`).
- Upgrade by starting from the next official release and porting the contracts below. Do not rewrite the existing published branches or restore the old browser implementation wholesale.

## Preserved contracts

- Atomic throwing two-token Keychain load reports `loaded`, `empty`, or `failed`. Failed reads preserve both in-memory tokens, including when the second read fails. Loading suppresses persistence observers.
- `reloadFromKeychain`, `onTokenPersist`, `retryPendingTokenWrites`, and `hasPendingTokenWrites` retain the host-facing contract. Writes and deletions are verified by read-back; failures retain captured intended values. Retries replay the latest pending refresh token first, followed by the ID token. Persistence bookkeeping and write/read-back use `NSRecursiveLock`; Sendable callbacks run after releasing it.
- Keychain service is `io.logto.client`, keys are `id_token` and `refresh_token`, and accessibility is explicitly `afterFirstUnlock`.
- `onTokenRefresh` reports returned-versus-changed flags without token values. Unchanged token values are not persisted, omitted refresh tokens retain the previous value, and cached access tokens need more than 60 seconds of remaining validity.
- URLSession preserves the original transport error when there is no HTTP response. A refresh permits one early `networkConnectionLost` retry only when the first failure arrives within one second and the task is not cancelled. The retry uses the remaining budget from two monotonic seconds after the original token exchange started. URLSession's request timeout is an idle timeout, not a guaranteed wall-clock deadline. Slow loss, timeout, cancellation, HTTP rejection, and a second failure are not retried. No server rotation or grace setting changes are required.
- Browser sign-in retains release `LogtoASWebAuthenticationSession`, HTTPS callback support, and the main-actor sign-in concurrency guard. It matches redirect scheme and host case-insensitively, and path and port exactly before state verification and token exchange. A callback is claimed once before any exchange.
- The optional public `presentationScene` parameter selects the caller's foreground-active window. Sign-in retains its resolved window and fails immediately with `noPresentationAnchor` when none exists. System cancellation remains the v2 `authFailed` error with the original system cancellation error attached. Browser sign-out retains the release behavior.
- Local `clearCredentials()` always clears access tokens and attempts both persisted-token deletions, including refresh-only and empty in-memory sessions. A captured refresh token is revoked after local clearing; offline revocation cannot restore it. An initially empty session retains the release `notAuthenticated` result after deletion attempts. Browser `signOut` keeps its separate release guards.
- ID-token verification retains the release JOSESwift verifier and configurable 300-second default tolerance, including expiry. This policy was explicitly approved for this upgrade. Signed fixtures prove the default expiry boundary without the old fork's verifier patch.

## Verification evidence

All commands ran from the candidate root on an arm64 iOS 18.6 iPhone 16 Pro simulator, ID `EC29B568-6556-4E70-9D76-34803D2B0D5B`, using normal Xcode access.

Common invocation:

```bash
xcodebuild test -scheme LogtoSDK-Package \
  -destination 'platform=iOS Simulator,id=EC29B568-6556-4E70-9D76-34803D2B0D5B' \
  -derivedDataPath /private/tmp/calido-logto-swift-derived \
  -resultBundlePath /private/tmp/calido-logto-swift-RESULT.xcresult
```

- Baseline: 87 release tests passed. Result: `/private/tmp/calido-logto-swift-baseline.xcresult`. This did not prove Keychain durability; the bare package runner logged missing Keychain entitlements.
- First red run: runtime assertions demonstrated acceptance of host/path prefix collisions and token exchange, reuse of a cached token inside the 60-second margin, loss of the original transport error, and absent response-loss recovery. Result: `/private/tmp/calido-logto-swift-red.xcresult`. One additional positive-test failure was corrected by resetting the shared test session request counter.
- Restored persistence and telemetry tests come from the previous fork. Missing release APIs are an API compatibility gap, not a claimed runtime red test.
- Second red run, with real-Keychain tests explicitly separated: four assertions failed for duplicate token exchange, missing-anchor startup/cause, and load observer callbacks. Result: `/private/tmp/calido-logto-swift-browser-red.xcresult`.
- The signed default expiry fixture passed unchanged release verification at `exp + 299`, and rejected `exp + 300` and `exp + 301` with `jwtExpired`; the existing signed issued-time boundaries remain covered.
- Final full candidate run: 132 tests executed. The six real-Keychain cases produced 18 failed assertions with missing-entitlement OSStatus `-34018`; every other case passed. Result: `/private/tmp/calido-logto-swift-full.xcresult`. This full run failed and does not verify real Keychain durability.
- Test-only Sendable captures and browser-mock actor calls were corrected before the final deterministic run.
- Final deterministic run: 126 tests passed, zero failures, including 18 injected persistence cases. This invocation adds `-skip-testing:LogtoClientTests/LogtoClientPersistStorageTests` to the common command. Result: `/private/tmp/calido-logto-swift-deterministic.xcresult`; log: `/private/tmp/calido-logto-swift-deterministic.log`. New Swift compiler warnings were cleared; Xcode retained its unrelated AppIntents metadata extraction notice. The omitted real-storage cases remain unverified and their full-run failures remain above.

Real storage tests are `LogtoClientPersistStorageTests`; injected storage failure tests are `LogtoClientInjectedPersistStorageTests`. Excluding the real storage class does not turn its unsigned-runner failures into a pass.

## Remaining physical gates

Run the candidate in the signed Calido host on the approved physical iPhone and iPad matrix. Verify first-unlock/background restoration, real Keychain rotation and deletion, persistence retry after protected-data failures, preferred iPad scene presentation, cancellation/repeated sign-in, browser/HTTPS callback flows, and the installed candidate's lifecycle diagnostics. Simulator and package-test results do not close these gates or prove provider reuse-grace behavior on the network.

## IOS-058 refresh-only logout regression

- Red: `swift test --filter 'testClearCredentials|testRefreshOnlyLogoutDeletionFailure'` ran nine tests with 23 failing assertions against the previous candidate. Refresh-only and access-only credentials remained, revocation and persistence callbacks were skipped, and a failed deletion could not retain a nil retry intention. Log: `/private/tmp/ios058-sdk-red-complete.log`.
- Green: the same nine tests passed after moving local clearing ahead of the empty-session check. Log: `/private/tmp/ios058-sdk-green.log`.
- Full deterministic iOS simulator run using the common invocation with `-skip-testing:LogtoClientTests/LogtoClientPersistStorageTests`: 131 tests passed, zero failures. Result: `/private/tmp/ios058-sdk-deterministic.xcresult`; log: `/private/tmp/ios058-sdk-deterministic.log`. The previously documented bare-runner real-Keychain limitation remains; injected deletion-failure tests verify the shared persistence core, not physical Keychain availability.

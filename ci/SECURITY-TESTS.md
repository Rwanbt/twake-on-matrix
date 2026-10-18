# Twake Chat: fail-closed pull request workflow safety

Baseline fork SHA `331b82b7fa6601c8e82d0f9ab23404ad7a1fbd65`.

An untrusted PR must never receive an SSH private key or GitHub write
permission while analysis scripts or Flutter tests execute code from the
checkout. The earlier `tests.yaml` granted write scopes and read
`secrets.SSH_KEY` for both analysis and widget tests.

This patch gives the PR tests read-only access and no SSH secrets,
sets `persist-credentials: false`, and pins the test checkout,
Flutter, Rust and cache actions to reviewed SHAs. The preview workflow
now **skips fork PRs** before accessing build-time configuration or a
GitHub Pages write token. External contributors retain analysis/tests
without privileged deployment; same-repository PR previews remain.

## Deterministic local test

```sh
node --test ci/required-chat-ci.test.cjs
```

Baseline RED: two failed / one passed. After the patch: **three passed**.
Required GitHub Actions job is `.github/workflows/ci-required-security.yml`.

## Further release gates — not certified here

- Flutter analyze/widgets, generated build and Android/iOS/web binaries
- Real disposable Synapse tests for E2EE, cross-signing, lost keys,
  malicious event HTML, offline/reconnect and media access control
- Device keychain and local encryption, package provenance and SBOM
- Visual/accessibility tests on mobile/tablet/desktop and real devices
- Exact SHA Actions result, required checks and code ownership review

Do not claim production readiness or merge a Draft PR until these are
complete. If dependencies require private SSH Git URLs in a test,
pin a safe read-only credential fetch path in a separately reviewed,
non-fork-executable workflow rather than restoring secrets to PR jobs.

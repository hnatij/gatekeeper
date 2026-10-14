# Testing the GT gatekeeper fork locally

Manual steps to check a branch, for example after merging a new upstream version, before pushing it and tagging a `gtk` release.
Run every command from the root of the repo (`natro/gatekeeper`).

What these steps cover: the build, the unit tests, the Docker image, and a smoke test of the image.
What they don't cover: the e2e tests (`e2e/`, they need a Keycloak cluster), or a real login against Keycloak or Cognito.

---

## 0. Prerequisites

```bash
go version          # any version works, Go downloads the version required by go.mod
docker --version
git status          # should be clean, otherwise the binary is reported as "-dirty"
```

Your Go config (`~/.config/go/env`) has `GOSUMDB=off`, which blocks the download of the Go version required by `go.mod`, and `GOPROXY=direct`, which makes module downloads very slow. Set these variables in every terminal you use for the steps below:

```bash
export GOSUMDB=sum.golang.org   # allows Go to download the right toolchain (go 1.27.x)
export GOPROXY=https://proxy.golang.org,direct   # your config has GOPROXY=direct (clones every module with git, very slow)
export GOFLAGS=-mod=mod         # ignores the local vendor/ folder (only Dockerfile.local uses it)
```

Check:

```bash
go version   # -> go version go1.27.x linux/amd64
```

---

## 1. Static checks and build

```bash
go vet ./...
```

Expected: no output.

```bash
mkdir -p bin
CGO_ENABLED=0 go build -tags netgo \
  -ldflags "-s -w -X github.com/gogatekeeper/gatekeeper/pkg/proxy/core.release=$(git describe --tags) -X github.com/gogatekeeper/gatekeeper/pkg/proxy/core.gitsha=$(git describe --always --dirty) -X github.com/gogatekeeper/gatekeeper/pkg/proxy/core.compiled=$(date +%s)" \
  -o bin/gatekeeper cmd/keycloak/gatekeeper-keycloak.go

./bin/gatekeeper --version
```

Expected: `gatekeeper version 5.0.0-...`, the version comes from the nearest git tag.

Check that the flags added by the fork are present:

```bash
./bin/gatekeeper --help | grep -E -- '--(enable-external-idp-enrichment|extidp-|enable-idp-reconnect|idp-reconnect-interval)'
```

Expected: 9 flags (`enable-external-idp-enrichment`, the 7 `extidp-*` flags, `enable-idp-reconnect`, `idp-reconnect-interval`).
If any are missing, a customization was lost in the merge.

---

## 2. Unit tests

```bash
go test ./pkg/... 2>&1 | tee /tmp/gatekeeper-tests.log | grep -E '^(ok|FAIL)\s'
```

Takes about 2 minutes. Then list the failing tests:

```bash
grep -oE '^--- FAIL: [A-Za-z0-9_]+' /tmp/gatekeeper-tests.log | sort -u
```

### Expected failures

These 5 tests fail **on purpose**. The upstream tests check upstream behaviour, and our customizations change that behaviour:

| Test                                         | Why it fails                                                                      |
|----------------------------------------------|-----------------------------------------------------------------------------------|
| `TestExtractDiscoveryURIComponents`          | We accept Cognito discovery URIs, the test expects them to be rejected            |
| `TestTokenEncryptionLoginHandler`            | Refresh tokens are always compressed, the test expects them uncompressed          |
| `TestRefreshToken`                           | Same reason (always-compressed refresh tokens)                                    |
| `TestCustomHeadersHandler`                   | Missing claims produce an empty header, the test expects no header (anti-spoofing) |
| `TestCustomHeadersHandlerNoProxyNoRedirects` | Same reason                                                                       |

**Any other failure must be investigated.** Re-run a single test like this:

```bash
go test ./pkg/... -run '^TestMetricsMiddleware$' -count=3 -v 2>&1 | tail -30
```

### Known flaky tests

These tests depend on timing and sometimes fail, **upstream too** (a busy WSL machine running the whole suite in parallel makes it worse):

| Test                         | Why                                                                                         | Observed (2026-10-14)                 |
|------------------------------|---------------------------------------------------------------------------------------------|---------------------------------------|
| `TestMetricsMiddleware`      | Timing                                                                                      | Rare                                  |
| `TestCookieDomainHostHeader` | Token expires after 2s, test sleeps 2.5s, then expects a refresh: gets `303` instead of `200` | ~2/10 runs on clean upstream, ~3/10 on ours |
| `TestAccessTokenEncryption`  | Timing (token expiry)                                                                       | Rare                                  |

Re-run them alone a few times. If most runs pass, ignore it:

```bash
go test ./pkg/testsuite -run '^TestCookieDomainHostHeader$' -count=5 2>&1 | grep -E '^(ok|FAIL|--- FAIL)'
```

To prove a failure is upstream flakiness and not ours, run the same command on upstream (see the worktree trick below, with `upstream/master` instead of `origin/natro`).

### Optional: compare with the previous version of natro

If you are not sure whether a failure comes from the merge, run the same tests on the last pushed `natro` (before your merge) in a separate folder:

```bash
git fetch origin
git worktree add --detach /tmp/gk-prev origin/natro
(cd /tmp/gk-prev && go test ./pkg/... 2>&1 | grep -oE '^--- FAIL: [A-Za-z0-9_]+' | sort -u)
git worktree remove --force /tmp/gk-prev
```

If the failure also happens there, the merge didn't introduce it.

### Optional: check that the customizations survived the merge

Our customizations are the difference between our branch and upstream. This difference should be the same before and after the merge:

```bash
# before: last pushed natro vs the upstream commit it was based on
git diff $(git merge-base origin/natro upstream/master) origin/natro | grep -v '^index' > /tmp/custom-before.diff
# after: your merged natro vs the upstream commit you just merged
git diff upstream/master HEAD | grep -v '^index' > /tmp/custom-after.diff

diff /tmp/custom-before.diff /tmp/custom-after.diff && echo "customizations identical"
```

Only differences you made on purpose should show up (for example `Dockerfile.local`, or this file).

---

## 3. Docker image

The normal `Dockerfile` downloads the Go modules inside the container, and the corporate TLS proxy blocks that (`x509: certificate signed by unknown authority`).
`Dockerfile.local` instead uses a `vendor/` folder prepared on the host, where the downloads work:

```bash
go mod vendor
```

Re-run it every time `go.mod` changes. A stale `vendor/` causes the `inconsistent vendoring` error.

```bash
docker buildx build --load --platform linux/amd64 \
  -f Dockerfile.local \
  --build-arg BASE_IMG=alpine:3.24.2 \
  -t gatekeeper:local-test .
```

Use the same `BASE_IMG` as production (see `BASE_IMG` in `dxcgt-docker-image-store/AIA-SProxy/gatekeeper/env.sh` and `sproxy-inventory.json`).

---

## 4. Smoke test of the image

```bash
# 1. the image starts and reports its version
docker run --rm gatekeeper:local-test --version

# 2. the fork-specific flags are in the image (expect 9 lines)
docker run --rm gatekeeper:local-test --help 2>&1 | grep -E -- '--(enable-external-idp-enrichment|extidp-|enable-idp-reconnect|idp-reconnect-interval)'

# 3. it runs as the non-root user 1000 (expect 1000)
docker run --rm --entrypoint /bin/sh gatekeeper:local-test -c 'id -u'

# 4. the HTML templates are included (expect 5 *.html.tmpl files)
docker run --rm --entrypoint /bin/sh gatekeeper:local-test -c 'ls /opt/gatekeeper/templates'
```

Checks 3 and 4 need a shell, so they only work with an alpine base image, not `scratch`.

---

## 5. Clean up

```bash
docker rmi gatekeeper:local-test
rm -rf bin/        # vendor/ can stay, it is git-ignored
```

---

## Troubleshooting

| Error                                                                                        | Cause / fix                                                                         |
|----------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------|
| `go: download go1.27.x ... checksum database disabled by GOSUMDB=off`                        | `export GOSUMDB=sum.golang.org` (step 0)                                            |
| `inconsistent vendoring` (host)                                                              | `export GOFLAGS=-mod=mod` (step 0)                                                  |
| `inconsistent vendoring` (docker build)                                                      | `go mod vendor` before building (step 3)                                            |
| `x509: certificate signed by unknown authority` in docker build                              | You used `Dockerfile` instead of `-f Dockerfile.local`                              |
| `go.mod requires go >= 1.xx` in docker build                                                 | Update the `golang:1.xx` image in `Dockerfile.local` to the version in `go.mod`     |

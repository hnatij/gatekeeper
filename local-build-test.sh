#!/bin/bash
#
# Local validation of the GT gatekeeper fork, to run before pushing a branch / tagging a gtk release.
#
#   1) go vet + build the binary (bin/gatekeeper)
#   2) run the unit tests, the failures expected because of the fork customizations are tolerated
#   3) build the docker image with Dockerfile.local (vendored deps, works behind the corporate TLS proxy)
#   4) smoke test the image (version, custom flags, runtime user, templates)
#
# Usage: ./local-build-test.sh [--skip-tests] [--no-docker] [--image <name:tag>] [--base-img <image>]
#
# NB: the e2e tests (e2e/) are not run, they need a Keycloak cluster

set -euo pipefail

cd "$(dirname "$0")"

IMAGE="gatekeeper:local-test"
BASE_IMG="alpine:3.24.1"
SKIP_TESTS=false
NO_DOCKER=false

## Tests failing by design because of the fork customizations (see BOGBERT_CHANGES.md on bogbert/bogbert):
##  - TestExtractDiscoveryURIComponents: Cognito discovery URIs are accepted
##  - TestTokenEncryptionLoginHandler, TestRefreshToken: refresh tokens are always compressed
##  - TestCustomHeadersHandler*: headers mapped from missing claims are written with an empty value
## Any other failure makes the script fail.
EXPECTED_FAILURES=(
    TestExtractDiscoveryURIComponents
    TestTokenEncryptionLoginHandler
    TestRefreshToken
    TestCustomHeadersHandler
    TestCustomHeadersHandlerNoProxyNoRedirects
)

## Flags added by the fork, they must be exposed by the built binary
EXPECTED_FLAGS=(
    --enable-external-idp-enrichment
    --extidp-users-file
    --extidp-match-claim
    --extidp-users-file-match-field
    --extidp-user-filter
    --extidp-user-filter-is-regex
    --extidp-users-file-reload-interval
    --enable-idp-reconnect
    --idp-reconnect-interval
)

while [ $# -gt 0 ]; do
    case "$1" in
        --skip-tests) SKIP_TESTS=true ;;
        --no-docker)  NO_DOCKER=true ;;
        --image)      IMAGE="$2"; shift ;;
        --base-img)   BASE_IMG="$2"; shift ;;
        -h|--help)    sed -n '2,13p' "$0"; exit 0 ;;
        *) echo "ERROR: unknown option '$1'" >&2; exit 1 ;;
    esac
    shift
done

## The local Go config has GOSUMDB=off, which prevents the download of the toolchain required by go.mod
export GOSUMDB="${GOSUMDB_OVERRIDE:-sum.golang.org}"
## The vendor/ directory is only used by Dockerfile.local, the host build uses the module cache
export GOFLAGS=-mod=mod

LOG_DIR="$(mktemp -d)"
trap 'rm -rf "${LOG_DIR}"' EXIT

step() { printf '\n\033[1;37m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[0;32mOK\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAILED\033[0m %s\n' "$*" >&2; exit 1; }

command -v go >/dev/null || fail "go is not installed"
$NO_DOCKER || command -v docker >/dev/null || fail "docker is not installed"

#
# 1) Binary
#
step "go vet"
go vet ./... || fail "go vet"
ok "go vet"

step "Building bin/gatekeeper"
TAG=$(git describe --tags 2>/dev/null || echo unknown)
GIT_SHA=$(git --no-pager describe --always --dirty)
LFLAGS="-X github.com/gogatekeeper/gatekeeper/pkg/proxy/core.release=${TAG} -X github.com/gogatekeeper/gatekeeper/pkg/proxy/core.gitsha=${GIT_SHA} -X github.com/gogatekeeper/gatekeeper/pkg/proxy/core.compiled=$(date '+%s')"
mkdir -p bin
CGO_ENABLED=0 go build -tags netgo -ldflags "-s -w ${LFLAGS}" -o bin/gatekeeper cmd/keycloak/gatekeeper-keycloak.go || fail "go build"
ok "$(./bin/gatekeeper --version 2>/dev/null | grep 'gatekeeper version')"

#
# 2) Unit tests
#
if $SKIP_TESTS; then
    step "Unit tests skipped"
else
    step "Running unit tests (takes a couple of minutes)"
    go test ./pkg/... > "${LOG_DIR}/test.log" 2>&1 || true
    grep -E '^(ok|FAIL)\s' "${LOG_DIR}/test.log" || true

    mapfile -t FAILED < <(grep -oE '^--- FAIL: [A-Za-z0-9_]+' "${LOG_DIR}/test.log" | awk '{print $3}' | sort -u)
    if grep -qE '^(panic:|FAIL\s.*\[build failed\]|# )' "${LOG_DIR}/test.log"; then
        cat "${LOG_DIR}/test.log"
        fail "unit tests did not compile or panicked"
    fi

    UNEXPECTED=()
    for t in "${FAILED[@]}"; do
        if printf '%s\n' "${EXPECTED_FAILURES[@]}" | grep -qx "$t"; then
            echo "expected failure: $t"
            continue
        fi
        ## Some tests are timing sensitive (e.g. TestMetricsMiddleware), give them a second chance
        echo "unexpected failure: $t, retrying it alone..."
        if go test ./pkg/... -run "^${t}\$" > "${LOG_DIR}/retry.log" 2>&1; then
            echo "  passed on retry (flaky): $t"
        else
            grep -E -A15 "^--- FAIL: ${t}" "${LOG_DIR}/retry.log" | head -40
            UNEXPECTED+=("$t")
        fi
    done

    for t in "${EXPECTED_FAILURES[@]}"; do
        printf '%s\n' "${FAILED[@]}" | grep -qx "$t" || echo "NOTE: $t is no longer failing, it can be removed from EXPECTED_FAILURES"
    done

    [ ${#UNEXPECTED[@]} -eq 0 ] || fail "unexpected test failures: ${UNEXPECTED[*]}"
    ok "unit tests (only the expected fork-specific failures)"
fi

$NO_DOCKER && { step "Docker steps skipped"; exit 0; }

#
# 3) Docker image
#
step "Refreshing vendor/ (used by Dockerfile.local)"
go mod vendor || fail "go mod vendor"
ok "vendor/"

step "Building docker image ${IMAGE} (base image: ${BASE_IMG})"
docker buildx build --load --platform linux/amd64 --force-rm=true \
    -f Dockerfile.local --build-arg "BASE_IMG=${BASE_IMG}" -t "${IMAGE}" . || fail "docker build"
ok "${IMAGE}"

#
# 4) Smoke test of the image
#
step "Smoke testing ${IMAGE}"
VERSION=$(docker run --rm "${IMAGE}" --version 2>/dev/null | grep 'gatekeeper version') || fail "the image does not run"
ok "$VERSION"

docker run --rm "${IMAGE}" --help > "${LOG_DIR}/help.txt" 2>&1 || true
for f in "${EXPECTED_FLAGS[@]}"; do
    grep -q -- "${f}\b" "${LOG_DIR}/help.txt" || fail "flag ${f} missing from the image"
done
ok "all ${#EXPECTED_FLAGS[@]} fork-specific flags are present"

## The checks below need a shell in the image, so they are skipped for a scratch base image
if docker run --rm --entrypoint /bin/sh "${IMAGE}" -c true >/dev/null 2>&1; then
    USER_ID=$(docker run --rm --entrypoint /bin/sh "${IMAGE}" -c 'id -u')
    [ "$USER_ID" = "1000" ] || fail "the image runs as uid ${USER_ID}, expected 1000"
    ok "runs as uid 1000"
    docker run --rm --entrypoint /bin/sh "${IMAGE}" -c 'ls /opt/gatekeeper/templates/*.html.tmpl >/dev/null' || fail "templates missing"
    ok "templates present"
fi

step "All checks passed"
echo "Image: ${IMAGE}"
echo "NB: the e2e tests were not run, and the image is only tagged locally (not pushed)"

#!/bin/bash
#
# Local validation of the GT gatekeeper fork, to run before pushing a branch / tagging a gtk release.
#
#   1) go vet + build the binary (bin/gatekeeper)
#   2) run the unit tests, the failures expected because of the fork customizations are tolerated
#   3) build the docker image with Dockerfile.local (vendored deps, works behind the corporate TLS proxy)
#   4) smoke test the image (version, custom flags, runtime user, templates)
#   5) with --release: create the git tag that the CodeBuild buildspec checks out (it never creates tags itself)
#
# Usage: ./local-build-test.sh [--skip-tests] [--no-docker] [--image <name:tag>] [--base-img <image>]
#                              [--release gg-<version>-gtk<n>]
#
#   --release gg-5.0.0-gtk2   same value as the "tag" of gatekeeper in dxcgt-docker-image-store sproxy-inventory.json
#                             creates the annotated tag v5.0.0-gtk2 on HEAD once all the checks passed
#                             the tag is NOT pushed, the push commands are printed at the end
#
# NB: the e2e tests (e2e/) are not run, they need a Keycloak cluster

set -euo pipefail

cd "$(dirname "$0")"

IMAGE="gatekeeper:local-test"
BASE_IMG="alpine:3.24.2"
SKIP_TESTS=false
NO_DOCKER=false
RELEASE=""
RELEASE_BRANCH="natro"

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
        --release)    RELEASE="$2"; shift ;;
        -h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "ERROR: unknown option '$1'" >&2; exit 1 ;;
    esac
    shift
done

## The local Go config has GOSUMDB=off, which prevents the download of the toolchain required by go.mod
export GOSUMDB="${GOSUMDB_OVERRIDE:-sum.golang.org}"
## The local Go config has GOPROXY=direct, which clones every module with git (very slow), use the module proxy
export GOPROXY="${GOPROXY_OVERRIDE:-https://proxy.golang.org,direct}"
## The vendor/ directory is only used by Dockerfile.local, the host build uses the module cache
export GOFLAGS=-mod=mod

LOG_DIR="$(mktemp -d)"
trap 'rm -rf "${LOG_DIR}"' EXIT

step() { printf '\n\033[1;37m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[0;32mOK\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAILED\033[0m %s\n' "$*" >&2; exit 1; }

command -v go >/dev/null || fail "go is not installed"
$NO_DOCKER || command -v docker >/dev/null || fail "docker is not installed"

## Base image freshness: warn when a newer Alpine release exists, it usually brings security fixes
## Not fatal, CodeBuild uses the baseImg of sproxy-inventory.json anyway
if [[ "${BASE_IMG}" =~ ^alpine:[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    LATEST_ALPINE=$(curl -fsS --max-time 10 https://alpinelinux.org/releases.json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
branch = next(b for b in d["release_branches"] if b["rel_branch"] == d["latest_stable"])
print(branch["releases"][0]["version"])' 2>/dev/null) || LATEST_ALPINE=""

    if [ -z "${LATEST_ALPINE}" ]; then
        echo "NOTE: could not check the latest Alpine release (no network?), using ${BASE_IMG}"
    elif [ "${BASE_IMG}" != "alpine:${LATEST_ALPINE}" ]; then
        printf '\033[0;33mWARNING\033[0m %s is not the latest Alpine release, alpine:%s is available\n' "${BASE_IMG}" "${LATEST_ALPINE}"
        echo "        update BASE_IMG in Dockerfile.local, this script, LOCAL_TESTING.md and in dxcgt-docker-image-store"
        echo "        (AIA-SProxy/sproxy-inventory.json baseImg + AIA-SProxy/gatekeeper/env.sh), or use --base-img alpine:${LATEST_ALPINE}"
    else
        ok "${BASE_IMG} is the latest Alpine release"
    fi
fi

#
# 0) Release pre-checks, done first so that we don't wait for the tests to find out the tag can't be created
#
if [ -n "${RELEASE}" ]; then
    step "Checking that ${RELEASE} can be released"

    ## Same conversion as in gatekeeper.buildspec.yml: gg-5.0.0-gtk2 -> v5.0.0-gtk2
    [[ "${RELEASE}" =~ ^gg-([0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?)-gtk([0-9]+)$ ]] \
        || fail "--release must look like gg-<version>-gtk<n> (e.g. gg-5.0.0-gtk2), got '${RELEASE}'"
    RELEASE_VERSION="${BASH_REMATCH[1]}"
    TAG_NAME="v${RELEASE_VERSION}-gtk${BASH_REMATCH[3]}"

    ## A release is only meaningful if everything was checked
    { $SKIP_TESTS || $NO_DOCKER; } && fail "--release can't be combined with --skip-tests or --no-docker"

    ## The tag must point to a commit that contains everything, and that CodeBuild can clone
    [ -z "$(git status --porcelain --untracked-files=no)" ] || fail "uncommitted changes, commit them first (the tag would not include them)"
    [ "$(git branch --show-current)" = "${RELEASE_BRANCH}" ] || fail "releases are made from the ${RELEASE_BRANCH} branch, you are on '$(git branch --show-current)'"
    git fetch -q origin "${RELEASE_BRANCH}" || fail "can't fetch origin/${RELEASE_BRANCH}"
    [ "$(git rev-parse HEAD)" = "$(git rev-parse "origin/${RELEASE_BRANCH}")" ] \
        || fail "HEAD is not the same as origin/${RELEASE_BRANCH}, push the branch first (git push origin ${RELEASE_BRANCH}) or pull"

    git rev-parse -q --verify "refs/tags/${TAG_NAME}" >/dev/null && fail "tag ${TAG_NAME} already exists locally, bump the gtk number"
    [ -z "$(git ls-remote --tags origin "refs/tags/${TAG_NAME}")" ] || fail "tag ${TAG_NAME} already exists on origin, bump the gtk number"

    ## The version in the name must be the upstream gogatekeeper version natro is based on
    UPSTREAM_VERSION=$(git describe --tags --abbrev=0 --exclude 'v*' HEAD)
    [ "${UPSTREAM_VERSION}" = "${RELEASE_VERSION}" ] \
        || fail "natro is based on upstream ${UPSTREAM_VERSION}, but the release is named for ${RELEASE_VERSION}"

    ok "${TAG_NAME} will be created on $(git rev-parse --short HEAD) once all the checks passed"
fi

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
[ -n "${RELEASE}" ] && echo "NB: ${TAG_NAME} is only created at the end, the image built by CodeBuild from it will report ${TAG_NAME}"

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
        ## Some tests are timing sensitive, upstream too (e.g. TestMetricsMiddleware, TestCookieDomainHostHeader),
        ## give them up to 3 more chances
        echo "unexpected failure: $t, retrying it alone..."
        PASSED=false
        for attempt in 1 2 3; do
            if go test ./pkg/... -run "^${t}\$" -count=1 > "${LOG_DIR}/retry.log" 2>&1; then
                PASSED=true
                break
            fi
            echo "  attempt ${attempt} failed"
        done
        if $PASSED; then
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

#
# 5) Release tag
#
if [ -n "${RELEASE}" ]; then
    step "Creating the release tag ${TAG_NAME}"
    ## HEAD must not have moved while the checks were running
    [ "$(git rev-parse HEAD)" = "$(git rev-parse "origin/${RELEASE_BRANCH}")" ] || fail "HEAD changed during the checks, run the script again"
    git tag -a "${TAG_NAME}" -m "${RELEASE}: gatekeeper ${RELEASE_VERSION} + GT customizations"
    ok "${TAG_NAME} -> $(git rev-parse --short "${TAG_NAME}^{commit}")"

    echo
    echo "Next steps:"
    echo "  1) push the tag:            git push origin ${TAG_NAME}"
    echo "  2) check it's on GitHub:    git ls-remote --tags origin ${TAG_NAME}"
    echo "  3) dxcgt-docker-image-store: set \"tag\": \"${RELEASE}\" for gatekeeper in AIA-SProxy/sproxy-inventory.json"
    echo "                               and add the changelog line in AIA-SProxy/gatekeeper/env.sh"
    echo "  4) in the CodeBuild log, check for: Tag '${TAG_NAME}' found"
    echo
    echo "To undo the tag before it's pushed: git tag -d ${TAG_NAME}"
fi

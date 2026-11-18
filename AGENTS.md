# AGENTS.md

## What this repo is

A build pipeline, not a fork. It builds the ingress-nginx controller image from
[chainguard-forks/ingress-nginx](https://github.com/chainguard-forks/ingress-nginx)
(a security-fix-only fork of the archived upstream) and publishes it to
`ghcr.io/glueops/ingress-nginx/controller`. No upstream source is stored here.

## Repo map

- `build.sh`: clones the fork at a tag and builds the image for the host architecture
  (nginx base from source, Go binaries, controller image).
- `test/smoke.sh`, `test/values.yaml`: image checks plus a k3d test using the upstream
  Helm chart with the platform's values.
- `image-exists.sh`: tells "tag exists" from "tag missing" from "registry error".
- `.github/workflows/build.yml`: daily `discover` → `build` (per arch) → `publish` →
  `notify`.
- `.github/configs/labeler.yml`: synced from the org; do not edit.

## Build and test

Everything runs in Docker; install nothing on the host.

```bash
UPSTREAM_TAG=controller-v1.15.15 ./build.sh
test/smoke.sh ghcr.io/glueops/ingress-nginx/controller:v1.15.15-amd64
docker run --rm -v "$PWD":/w -w /w rhysd/actionlint:1.7.7
docker run --rm -v "$PWD":/w -w /w koalaman/shellcheck:v0.10.0 build.sh image-exists.sh test/smoke.sh
```

A pull request that touches the workflow or scripts builds and smoke-tests both
architectures without publishing.

## Rules

- The version comes from the upstream tag name. The fork's `TAG` and `Chart.yaml` are
  stale; never read versions from them.
- Always build the nginx base from the fork and pass it as `BASE_IMAGE`. The fork's
  `NGINX_BASE` default points at upstream's old nginx without the security patches, and
  a build on it still succeeds.
- The `build` job must not get registry credentials. It runs third-party source and
  pull request code; only `publish` can write.
- Values from upstream (tag names, SHAs) are validated against a strict pattern and
  passed to scripts through `env:`, never `${{ }}` inside `run:`.
- Do not copy code from `porter-dev/ingress-nginx`. It does the same job but has no
  license.

## Decisions

Settled; do not re-raise in reviews.

- GHCR only, authenticated with `GITHUB_TOKEN`. No Docker Hub.
- One minor line (1.15). A new upstream minor opens an issue and is adopted by changing
  the tag pattern on purpose, not automatically.
- `linux/amd64` and `linux/arm64`. No `arm/v7`.
- Only the newest upstream tag is built, once. `v1.15.N` is never overwritten and there
  are no rebuilds of the same tag, so Alpine package fixes arrive with the next upstream
  tag.
- The `-amd64` and `-arm64` tags are inputs to the multi-arch tag. They may be re-pushed
  when a failed publish is retried, and they must be kept: do not add a cleanup of
  untagged or per-arch versions, it would break the multi-arch tag.
- The image tag in GHCR is the only release marker. No git tags, GitHub Releases or
  release-please here.
- Image only. The platform keeps using the upstream Helm chart 4.15.1; no chart is
  published.
- No attestation, signing or vulnerability scan until something verifies or acts on
  them.
- The pull request build is not a required check: its paths filter would leave other
  pull requests waiting forever.
- Write access to this repo is publish access: a writer can run an edited workflow from
  a branch. The org ruleset protects `main`, not the package.
- If Chainguard stops tagging, the pipeline stays green and says nothing. Accepted;
  their release gaps are too irregular for an age alarm.
- No `renovate.json`: the org Renovate bot keeps the action pins current without one.
  The tool image pins in `test/smoke.sh` are bumped by hand.
- No keepalive for the schedule. GitHub disables it after 60 days without repository
  activity; merging Renovate pull requests is what keeps it on (see README).

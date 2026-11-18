# ingress-nginx

Builds the ingress-nginx controller image that the GlueOps platform runs.

The upstream project, [kubernetes/ingress-nginx](https://github.com/kubernetes/ingress-nginx),
was archived in March 2026 and no longer gets security fixes.
[Chainguard maintains a fork](https://github.com/chainguard-forks/ingress-nginx) that
backports fixes, but publishes source only. This repo builds that source, unmodified,
and publishes the image.

## Using the image

```
ghcr.io/glueops/ingress-nginx/controller:v1.15.N
```

- Tags match Chainguard's `controller-v1.15.N` tags. A tag is built once and never
  overwritten, so it is safe to pin by tag and digest.
- Multi-arch: `linux/amd64` and `linux/arm64`.
- Versions are listed on the
  [package page](https://github.com/GlueOps/ingress-nginx/pkgs/container/ingress-nginx%2Fcontroller).
  The image labels carry the Chainguard commit it was built from
  (`org.opencontainers.image.revision`).
- Use it with the upstream Helm chart `ingress-nginx` 4.15.1. Pod labels will still say
  app version 1.15.1, because they come from the chart.

## How updates happen

A daily workflow ([build.yml](.github/workflows/build.yml)) looks for the newest
`controller-v1.15.N` tag in Chainguard's fork. If that version is not published yet, it
builds nginx and the controller from source for both architectures, smoke-tests each
image, and only then publishes. Renovate is expected to then propose the new tag in the
platform chart.

Only the newest tag is built. If Chainguard publishes two tags between runs, the older
one gets no image; the newer one contains its fixes.

## Building and testing locally

Both scripts need only Docker and git. Building nginx from source takes a while.

```bash
UPSTREAM_TAG=controller-v1.15.15 ./build.sh
test/smoke.sh ghcr.io/glueops/ingress-nginx/controller:v1.15.15-amd64
```

`build.sh` builds for the machine's own architecture (the tag ends in `-arm64` on an
ARM machine) and leaves the image in the local Docker image store. Nothing is pushed.

## When the scheduled build fails

The workflow opens an issue titled "Scheduled ingress-nginx build is failing".

1. Open the linked run and find the failed job: `discover`, `build` (per architecture)
   or `publish`.
2. A failed `discover` or `build` publishes nothing. A `publish` that fails partway can
   leave the `-amd64`/`-arm64` tags pushed without the `v1.15.N` tag; nothing consumes
   those, and the next run replaces them. Either way the last published `v1.15.N`
   stays in use.
3. In a failed smoke test, read the `FAIL:` line. If one of the checks failed, the new
   upstream tag did not behave: do not work around the test, stay on the previous image
   and investigate. If it stopped earlier (creating the cluster, pulling a tool image or
   the Helm chart), it is an outage elsewhere; run it again.
4. To retry, use "Run workflow" on `main` or "Re-run all jobs". "Re-run failed jobs"
   only works the same day, because the built images are kept for one day. The next
   daily run retries anyway.
5. Close the issue once a run succeeds.

GitHub turns off scheduled workflows in a public repo after 60 days without repository
activity, and a workflow that is off cannot report anything. Merging the Renovate pull
requests for the pinned actions keeps it on. If the schedule has been disabled,
re-enable the workflow from the Actions tab.

## Licensing

This repo's scripts are Apache-2.0 (see [LICENSE](LICENSE)), as is ingress-nginx. The
image also contains third-party components under their own licenses, including nginx,
LuaJIT, ModSecurity and Alpine packages.

This project is not affiliated with or endorsed by Chainguard, the Kubernetes project
or F5/NGINX. Report problems with these images here, not to Chainguard.

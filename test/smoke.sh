#!/usr/bin/env bash
# Smoke-tests a locally built controller image before it is published.
# Usage: test/smoke.sh ghcr.io/glueops/ingress-nginx/controller:v1.15.15-amd64
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

image=${1:?usage: smoke.sh <image>:<version>-<arch>}
tag=${image##*:}
version=${tag%-*}

K3D=ghcr.io/k3d-io/k3d:5.8.3@sha256:0a9d521e3d14b740e2f407ef549db6a252ac37ac0f331e3dc39657859424d969
K3S=rancher/k3s:v1.33.5-k3s1@sha256:fd4740667b7033055c27d424d0d2d660bf66cedbdb225d68e0eab6dd48aa0fd2
HELM=alpine/helm:3.17.3@sha256:d899e6316789fec04ee95300a18e454b7942539cbb3d89bde3e0655d6ca2e895
CURL=curlimages/curl:8.11.1@sha256:c1fe1679c34d9784c1b0d1e5f62ac0a79fca01fb6377cdd33e90473c6f9f9a69
CHART_VERSION=4.15.1
CHART_SHA256=3eff0bd18151d6e6b1c441463410571443dda1ac78292cb189346628de784f0c

ns=glueops-core-public-ingress-nginx
deploy=public-ingress-nginx-controller
host=smoke.example.com
cluster=nginx-smoke-$RANDOM
node=k3d-$cluster-server-0

fail() { echo "FAIL: $*" >&2; exit 1; }
in_image() { docker run --rm --entrypoint "$1" "$image" "${@:2}"; }
k3d() { docker run --rm -v /var/run/docker.sock:/var/run/docker.sock "$K3D" "$@"; }
kubectl() { docker exec -i "$node" kubectl "$@"; }

echo "== image checks"
release=$(in_image /nginx-ingress-controller --version)
grep -Eq "Release:[[:space:]]+$version\$" <<<"$release" || fail "controller does not report $version: $release"
in_image nginx -V >/dev/null 2>&1 || fail "nginx -V failed"
[[ $(in_image id -u) == 101 ]] || fail "image does not run as uid 101"
# max_headers exists only in Chainguard's nginx patches, so this fails on an
# unpatched base. A file with its own pid path: nginx reads a piped config as
# empty, and uid 101 cannot write the default pid file.
in_image sh -c 'printf "pid /tmp/nginx/t.pid;\nevents{}\nhttp{ max_headers 100; }\n" > /tmp/nginx/t.conf && nginx -t -c /tmp/nginx/t.conf' \
  || fail "nginx rejects max_headers: the image is not built on the patched base"

echo "== cluster checks"
cleanup() {
  rc=$?
  if ((rc != 0)); then
    kubectl -n "$ns" get pods -o wide || true
    kubectl -n "$ns" get events --sort-by=.lastTimestamp || true
    kubectl -n "$ns" logs "deploy/$deploy" -c controller --tail=200 || true
  fi
  k3d cluster delete "$cluster" >/dev/null 2>&1 || true
  exit "$rc"
}
trap cleanup EXIT

# Traefik is disabled so it does not take 443; servicelb stays so the
# controller's LoadBalancer Service is reachable on the node.
k3d cluster create "$cluster" --image "$K3S" --no-lb \
  --k3s-arg '--disable=traefik@server:0' --wait --timeout 180s
k3d image import "$image" -c "$cluster"

kubectl create namespace "$ns"
# Rendered and applied (not helm install) so no kubeconfig has to leave the node.
# pullPolicy Never: test the imported image, never a published copy of the tag.
docker run -i --rm --entrypoint sh "$HELM" -c "
  helm pull ingress-nginx --repo https://kubernetes.github.io/ingress-nginx --version $CHART_VERSION -d /tmp >/dev/null &&
  echo '$CHART_SHA256  /tmp/ingress-nginx-$CHART_VERSION.tgz' | sha256sum -c >/dev/null &&
  helm template public-ingress-nginx /tmp/ingress-nginx-$CHART_VERSION.tgz -n $ns -f - \
    --set controller.image.registry=${image%%/*} \
    --set controller.image.image=$(cut -d/ -f2- <<<"${image%:*}") \
    --set controller.image.tag=$tag \
    --set controller.image.pullPolicy=Never" <values.yaml | kubectl apply -f -

# The backend is nginx from the image under test, so nothing else is pulled.
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: backend, namespace: $ns}
spec:
  selector: {matchLabels: {app: backend}}
  template:
    metadata: {labels: {app: backend}}
    spec:
      containers:
        - name: backend
          image: $image
          imagePullPolicy: Never
          command: ["/bin/sh", "-c"]
          args:
            - |
              printf 'pid /tmp/nginx/b.pid;\nevents{}\nhttp{ server{ listen 8080; location / { return 200 ok; } } }\n' > /tmp/nginx/b.conf
              exec nginx -g 'daemon off;' -c /tmp/nginx/b.conf
          ports: [{name: web, containerPort: 8080}]
---
apiVersion: v1
kind: Service
metadata: {name: backend, namespace: $ns}
spec:
  selector: {app: backend}
  ports: [{name: web, port: 80, targetPort: web}]
EOF
kubectl -n "$ns" rollout status "deploy/$deploy" --timeout=180s
kubectl -n "$ns" rollout status deploy/backend --timeout=120s

# Applied after the controller is ready, so nginx reloads under the new binary.
# Named service port: the fork's Go changes touched port parsing.
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata: {name: smoke, namespace: $ns}
spec:
  ingressClassName: public
  rules:
    - host: $host
      http:
        paths:
          - path: /
            pathType: Prefix
            backend: {service: {name: backend, port: {name: web}}}
EOF

request() {
  docker run --rm --network "k3d-$cluster" "$CURL" -sk -o /dev/null --max-time 5 \
    -w '%{http_version} %{http_code}' --connect-to "$host:443:$node:443" "$1" "https://$host/" || true
}
# Until the Ingress syncs, ssl-reject-handshake refuses this host's handshake.
got=
for _ in $(seq 60); do
  got=$(request --http1.1)
  [[ $got == "1.1 200" ]] && break
  sleep 2
done
[[ $got == "1.1 200" ]] || fail "HTTP/1.1 over TLS: wanted '1.1 200', got '$got'"
# curl falls back to HTTP/1.1 silently, so the negotiated version is asserted.
got=$(request --http2)
[[ $got == "2 200" ]] || fail "HTTP/2 over TLS: wanted '2 200', got '$got'"

# Last, after the requests: a crashed worker is respawned and still answers 200.
restarts=$(kubectl -n "$ns" get pods -l app.kubernetes.io/component=controller \
  -o 'jsonpath={.items[*].status.containerStatuses[?(@.name=="controller")].restartCount}')
[[ $restarts == 0 ]] || fail "controller restart count is '$restarts'"
# Captured first: piping into grep -q under pipefail hides a match.
logs=$(kubectl -n "$ns" logs "deploy/$deploy" -c controller --tail=-1)
if grep -q 'exited on signal' <<<"$logs"; then
  fail "an nginx worker crashed"
fi

echo "PASS: $image"

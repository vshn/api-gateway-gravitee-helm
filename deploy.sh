#!/bin/sh
set -eu
RELEASE=gravitee-test
NAMESPACE="vshn-api-gateway-gravitee-test"
SECRET=values.secret.yaml
[ -f "$SECRET" ] || SECRET=values.secret.example.yaml

usage() {
  cat <<EOF
Usage: ./deploy.sh [flags]
  --local      add -f values-local.yaml and run the mongodb two-phase flow (kind)
  --diff       render/diff only, no cluster changes (requires helm-diff plugin)
  --create-ns  pass --create-namespace to helm (ns is provisioned by AppFlow on APPUiO)
  -h, --help   show this help

Default (no flags): single helm upgrade with values.yaml + secret (APPUiO prod).

Examples:
  ./deploy.sh --local --create-ns   # kind
  ./deploy.sh                       # APPUiO
  ./deploy.sh --diff --local        # diff only
EOF
}

LOCAL=
DIFF=
CREATE_NS=
while [ $# -gt 0 ]; do
  case "$1" in
    --local) LOCAL=1 ;;
    --diff) DIFF=1 ;;
    --create-ns) CREATE_NS="--create-namespace" ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

VALUES="-f values.yaml"
[ -z "$LOCAL" ] || VALUES="$VALUES -f values-local.yaml"
VALUES="$VALUES -f $SECRET"

helm dependency update .

if [ -n "$DIFF" ]; then
  if ! helm diff --help >/dev/null 2>&1; then
    echo "helm-diff plugin required: helm plugin install https://github.com/databus23/helm-diff --verify=false" >&2
    exit 1
  fi
  rc=0
  helm diff upgrade "$RELEASE" . -n "$NAMESPACE" $VALUES --allow-unreleased --detailed-exitcode || rc=$?
  case "$rc" in
    0) echo "No differences found."; exit 0 ;;
    2) echo "Differences found."; exit 1 ;;
    *) echo "Diff failed (exit $rc)." >&2; exit "$rc" ;;
  esac
fi

# postgres stack: no DB init phase needed (bundled postgres self-starts; gravitee retries until ready)
helm upgrade --install "$RELEASE" . -n "$NAMESPACE" $VALUES --timeout 10m $CREATE_NS

kubectl get pods -n "$NAMESPACE"
kubectl get svc -n "$NAMESPACE"
kubectl logs -n "$NAMESPACE" job/"$RELEASE"-init --tail=50 || true

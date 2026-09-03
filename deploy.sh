#!/bin/sh
set -eu
RELEASE=gravitee-test
NAMESPACE="vshn-api-gateway-gravitee-test"
SECRET=values.secret.yaml
[ -f "$SECRET" ] || SECRET=values.secret.example.yaml
MONGO_PASS=$(awk '/MONGODB_ROOT_PASSWORD:/{sub(/^[^:]*:[ \t]*/,""); gsub(/["'\'']/, ""); sub(/[ \t\r]+$/, ""); print; exit}' "$SECRET")
: "${MONGO_PASS:?no MONGODB_ROOT_PASSWORD found in $SECRET}"

helm dependency update .
helm upgrade --install "$RELEASE" . -n "$NAMESPACE" -f values.yaml -f "$SECRET" --set initJob.enabled=false --timeout 10m
kubectl wait pod/mongodb-0 -n "$NAMESPACE" --for=condition=Ready --timeout=300s
kubectl exec -n "$NAMESPACE" mongodb-0 -- mongosh -u root -p "$MONGO_PASS" --authenticationDatabase admin --quiet --eval "rs.initiate({_id:\"mongodb-nunki\",version:1,members:[{_id:0,host:\"mongodb-0.${NAMESPACE}.svc.cluster.local:27017\"}]})" || true
helm upgrade "$RELEASE" . -n "$NAMESPACE" -f values.yaml -f "$SECRET" --timeout 10m
kubectl get pods -n "$NAMESPACE"
kubectl get svc -n "$NAMESPACE"
kubectl logs -n "$NAMESPACE" job/"$RELEASE"-init --tail=50 || true

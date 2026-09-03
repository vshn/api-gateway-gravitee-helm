#!/bin/sh
set -eu
RELEASE=my-gravitee
NAMESPACE="gravitee"

helm dependency update .
helm upgrade --install "$RELEASE" . -n "$NAMESPACE" --create-namespace -f values.yaml -f values-local.yaml --set initJob.enabled=false --timeout 10m
kubectl wait pod/mongodb-0 -n "$NAMESPACE" --for=condition=Ready --timeout=300s
kubectl exec -n "$NAMESPACE" mongodb-0 -- mongosh -u root -p gravitee-kind-root --authenticationDatabase admin --quiet --eval 'rs.initiate({_id:"mongodb-nunki",version:1,members:[{_id:0,host:"mongodb-0.${NAMESPACE}.svc.cluster.local:27017"}]})' || true
helm upgrade "$RELEASE" . -n "$NAMESPACE" -f values.yaml -f values-local.yaml --timeout 10m
kubectl get pods -n "$NAMESPACE"
kubectl get svc -n "$NAMESPACE"
kubectl logs -n "$NAMESPACE" job/"$RELEASE"-init --tail=50 || true

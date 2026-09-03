#!/bin/sh
set -eu
RELEASE=gravitee-test
NAMESPACE="vshn-api-gateway-gravitee-test"
SECRET=values.secret.yaml
[ -f "$SECRET" ] || SECRET=values.secret.example.yaml

helm dependency update .
HELM_DIFF_USE_UPGRADE_DRY_RUN=true helm diff upgrade "$RELEASE" . -n "$NAMESPACE" -f values.yaml -f "$SECRET" --allow-unreleased
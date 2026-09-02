# Wrapper chart for [Gravitee APIM](https://github.com/gravitee-io/gravitee-api-management) (4.12.18)

Wrapper around `https://helm.gravitee.io` `apim:4.12.18` for APPUiO/AppFlow. See `/tmp/ref-litellm` for pattern reference.

## What it wraps
- `gravitee` (alias for `apim:4.12.18`): Management API, Gateway, Console UI, Portal. Bundled mongo/es disabled (`gravitee.mongodb.enabled=false`, `gravitee.elasticsearch.enabled=false`, `gravitee.es.enabled=false`).
- Extra: `httpbun` Deployment+Service (toggle `httpbun.enabled`), `init` Job hook creating V4 proxy API `/httpbun` -> httpbun, API_KEY plan, 3 apps/subs.

## Values
All subchart values namespaced under `gravitee:` (alias). Wrapper-only: `httpbun`, `initJob`, `env`.

```yaml
gravitee:
  api: {ingress: {management: {hosts: [your.host]}}}
  gateway: {ingress: {hosts: [your.host]}}
  oidcAuth: {enabled: false} # set when IdP ready; maps to api env OIDC
httpbun: {enabled: true}
initJob: {enabled: true, apiKeys: 3} # requires httpbun.enabled=true
```

IdP: configure via `gravitee.oidcAuth` (clientId, tokenEndpoint, authorizeEndpoint etc). Disabled by default (`enabled:false`); wire via env when IdP is ready. See `values.yaml` `gravitee.oidcAuth` comments. POC ref: `management-api/gravitee.yml:549-565`.

## Init behaviour
Post-install hook `templates/init-job.yaml` (like `setup-api.sh` but API_KEY not KEY_LESS). Guarded by `httpbun.enabled && initJob.enabled` — disable both together. Idempotent: reuses API/plan/app if exists, publishes plan (`validation: AUTO` so no admin approval), starts API, waits 6s for gateway sync. Creates 3 apps/subs (`app-1..app-N`, `initJob.apiKeys=3`) via Portal API with `AUTO` validation — no admin needed; fetch keys via Portal `GET /environments/DEFAULT/subscriptions?application={appId}` (or Management API equivalent).

Unauthorized `curl http://gateway/httpbun/get` -> `401` from gateway, never hits httpbun.

## Deploy (APPUiO)
```sh
helm dependency update .
helm upgrade --install my-gravitee . -n gravitee --create-namespace -f values.yaml
# httpbun disabled:
helm upgrade --install my-gravitee . --set httpbun.enabled=false --set initJob.enabled=false
```

## Local kind test

Bundled Bitnami Mongo fails on kind (`mkdir: cannot create directory '/bitnami/mongodb': Permission denied`). `values-local.yaml` disables it (`gravitee.mongodb.enabled=false`, `gravitee.mongo.rsEnabled=false`) and expects external `gravitee-mongodb` Service (`mongo:6.0 --noauth`).

```sh
# kind install + cluster
curl -Lo /tmp/kind https://kind.sigs.k8s.io/dl/v0.28.0/kind-linux-amd64 && chmod +x /tmp/kind && sudo mv /tmp/kind /usr/local/bin/kind
kind create cluster --name gravitee-test
kubectl cluster-info --context kind-gravitee-test

# external mongo workaround (gravitee-mongodb svc+deploy, mongo:6.0 --noauth, rsEnabled=false)
cat > /tmp/mongo.yaml <<'YAML'
apiVersion: v1
kind: Service
metadata: {name: gravitee-mongodb, namespace: gravitee}
spec: {ports: [{port: 27017}], selector: {app: gravitee-mongodb}}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: gravitee-mongodb, namespace: gravitee}
spec:
  selector: {matchLabels: {app: gravitee-mongodb}}
  template:
    metadata: {labels: {app: gravitee-mongodb}}
    spec:
      containers:
      - name: mongodb
        image: mongo:6.0
        args: [--noauth]
        ports: [{containerPort: 27017}]
YAML
kubectl apply -f /tmp/mongo.yaml

# deploy wrapper chart
helm dependency update .
helm upgrade --install my-gravitee . -n gravitee --create-namespace -f values.yaml -f values-local.yaml --timeout 10m
kubectl get pods -n gravitee
kubectl get svc -n gravitee

# verify gateway (401 without key, 200 with key from initJob logs)
kubectl port-forward -n gravitee svc/my-gravitee-gateway 9082:82 &
curl -s http://localhost:9082/httpbun/get  # 401
curl -H "X-Gravitee-Api-Key: <KEY>" http://localhost:9082/httpbun/get  # 200
# <KEY> from: kubectl logs -n gravitee job/my-gravitee-init  OR  kubectl get secret my-gravitee-init-keys -n gravitee -o jsonpath='{.data}' | jq
```

## Publishing
Tag `v*` triggers `.github/workflows/helm-release.yml` -> `oci://ghcr.io/<owner>/helm-charts`.

## AppFlow note
If adding `VSHNPostgreSQL`/`VSHNMongoDB` AppCat resource later (like `litellm/templates/vshnpostgresql.yaml`), apply CR before first Helm install — Helm installs deps before wrapper manifests.

## Ponytail
Kept 3 templates + 1 job. Skipped: custom gravitee.yml mount (use `gravitee.api.configuration`), extra Secrets/PDBs. Add when measured.

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
Fixed release name `gravitee` (like litellm) so names are predictable (`gravitee-gateway`, `gravitee-init`, ...).
```sh
helm dependency update .
helm upgrade --install gravitee . -n gravitee --create-namespace -f values.yaml
# httpbun disabled:
helm upgrade --install gravitee . --set httpbun.enabled=false --set initJob.enabled=false
```

## Local kind test

Bundled Bitnami Mongo fails on kind (`mkdir: cannot create directory '/bitnami/mongodb': Permission denied`). `values-local.yaml` disables it (`gravitee.mongodb.enabled=false`, `gravitee.mongo.rsEnabled=false`) and expects external `gravitee-mongodb` Service (`mongo:6.0 --noauth`).

```sh
# kind install + cluster
curl -Lo /tmp/kind https://kind.sigs.k8s.io/dl/v0.28.0/kind-linux-amd64 && chmod +x /tmp/kind && sudo mv /tmp/kind /usr/local/bin/kind
kind create cluster --name gravitee-test
kubectl cluster-info --context kind-gravitee-test

# deploy (fixed release `gravitee`): phase A hook off, rs.initiate, phase B hook on
./deploy.sh
kubectl get pods -n gravitee
kubectl get svc -n gravitee

# verify gateway (401 without key, 200 with key from initJob logs)
kubectl port-forward -n gravitee svc/gravitee-gateway 9082:82 &
curl -s http://localhost:9082/httpbun/get  # 401
curl -H "X-Gravitee-Api-Key: <KEY>" http://localhost:9082/httpbun/get  # 200
# <KEY> from: kubectl logs -n gravitee job/gravitee-init  OR  kubectl get secret my-gravitee-init-keys -n gravitee -o jsonpath='{.data}' | jq
```

### Local baseURLs (kind port-forwards)

With all ingresses disabled the chart falls back to `https://apim.example.com`, which is
unreachable from a browser. `values-local.yaml` pins reachable localhost URLs:

- `gravitee.ui.baseURL: http://localhost:8083/management` (console `constants.json`)
- `gravitee.portal.baseURL: http://localhost:8083/portal` (portal `assets/config.json`)
- `gravitee.installation.api.url: http://localhost:8083` (portal `/ui/bootstrap`; without it the portal UI ignores the ConfigMaps and calls `apim.example.com`)

Forward `8083:83` (api), `9082:82` (gateway), `8085:8003` (portal), `8084:8002` (console).
`values.yaml` (prod) stays free of localhost.

### Portal 2-key demo (screenshots in `docs/screenshots/`)

`01-login.png`, `02-api-detail.png` (httpbun PoC API), `03-application.png` (demo-app-1),
`04-subscription.png`, `05-key-1.png`, `06-key-2.png` (viewport 1280x800, `demo@example.com`).
Demo subscriptions were closed after the shoot, so pictured keys now return 401; gateway
proof during the shoot: no key 401, KEY1 200, KEY2 200.
Note: the `httpbun PoC API` needs lifecycleState PUBLISHED + visibility PUBLIC to appear
in the portal catalog (`PUT /management/v2/.../apis/{id}` with full body).

## Publishing
Tag `v*` triggers `.github/workflows/helm-release.yml` -> `oci://ghcr.io/<owner>/helm-charts`.

## AppFlow note
If adding `VSHNPostgreSQL`/`VSHNMongoDB` AppCat resource later (like `litellm/templates/vshnpostgresql.yaml`), apply CR before first Helm install — Helm installs deps before wrapper manifests.

## Ponytail
Kept 3 templates + 1 job. Skipped: custom gravitee.yml mount (use `gravitee.api.configuration`), extra Secrets/PDBs. Add when measured.

## CI (test)
Push triggers `.github/workflows/test.yml` (`environment: test`): fixed release
`my-gravitee` in namespace `gravitee` (from `KUBECONFIG_TEST` context namespace).
Preview builds `env.yaml`/`vars.yaml`/`secrets.yaml` from GH vars/secrets
(excluding `KUBECONFIG_*`) and runs `helm diff upgrade`; deploy runs
`helm upgrade --install --timeout 10m` with the same files.
`values-local.yaml` is never used in CI. `test-stop.yml` (manual) uninstalls.

## Kind
Local kind users run `./deploy.sh` (fixed release `my-gravitee`, namespace
`gravitee`): phase A installs with the init hook off, initiates the mongo
replica set, phase B upgrades with the hook on, then shows pods/svc + init log.

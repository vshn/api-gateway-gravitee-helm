# Wrapper chart for [Gravitee APIM](https://github.com/gravitee-io/gravitee-api-management) (4.12.18)

Wrapper around `https://helm.gravitee.io` `apim:4.12.18` for APPUiO/AppFlow. See `/tmp/ref-litellm` for pattern reference.

## What it wraps
- `gravitee` (alias for `apim:4.12.18`): Management API, Gateway, Console UI, Portal. Bundled mongo/es disabled (`gravitee.mongodb.enabled=false`, `gravitee.elasticsearch.enabled=false`, `gravitee.es.enabled=false`).
- Extra: `httpbun` Deployment+Service (toggle `httpbun.enabled`), `init` Job hook creating V4 proxy API `/httpbun` -> httpbun, API_KEY plan, 3 apps/subs.
- `postgresql` (`templates/postgresql.yaml`, gated by `postgresql.enabled`, `true` everywhere): single-replica Deployment + PVC; Gravitee uses it as JDBC repository (`gravitee.management.type=jdbc`, `gravitee.ratelimit.type=jdbc`; PostgreSQL driver is bundled in the APIM images). Set `postgresql.enabled=false` and point `gravitee.jdbc.url/username/password` at an external database instead.

## Values
All subchart values namespaced under `gravitee:` (alias). Wrapper-only: `httpbun`, `initJob`, `env`, `postgresql` (bundled DB; `true` in both `values.yaml` and `values-local.yaml`).

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

One way to deploy this is that the api and the gateway and the uis (portal and console) are on 3 different hosts.
Fixed release name `gravitee-test` (like litellm) so names are predictable (`gravitee-test-gateway`, `gravitee-test-init`, ...) in namespace `vshn-api-gateway-gravitee-test`.
```sh
helm dependency update .
# -f values.secret.yaml (git-ignored) falls back to values.secret.example.yaml, as in deploy.sh/test.yml
helm upgrade --install gravitee-test . -n vshn-api-gateway-gravitee-test --create-namespace -f values.yaml -f values.secret.yaml
# httpbun disabled:
helm upgrade --install gravitee-test . --set httpbun.enabled=false --set initJob.enabled=false -f values.secret.yaml
```

## Local kind test

Bundled postgres (`templates/postgresql.yaml`, `postgresql.enabled: true` in both `values.yaml` and `values-local.yaml`) provides a single replica; Gravitee's liquibase (`gravitee.jdbc.liquibase`, on by default) creates the schema on first Management API boot against the fresh DB. No manual init step needed — a single `helm upgrade --install` suffices (the init hook retries until the Management API is ready).

```sh
# kind install + cluster
curl -Lo /tmp/kind https://kind.sigs.k8s.io/dl/v0.28.0/kind-linux-amd64 && chmod +x /tmp/kind && sudo mv /tmp/kind /usr/local/bin/kind
kind create cluster --name gravitee-test
kubectl cluster-info --context kind-gravitee-test

# deploy (fixed release `gravitee-test`, or just run ./deploy.sh; layers values.yaml + values-local.yaml + secret)
./deploy.sh
kubectl get pods -n vshn-api-gateway-gravitee-test
kubectl get svc -n vshn-api-gateway-gravitee-test

# verify gateway (401 without key, 200 with key)
kubectl port-forward -n vshn-api-gateway-gravitee-test svc/gravitee-test-gateway 9082:82 &
curl -s http://localhost:9082/httpbun/get  # 401
curl -H "X-Gravitee-Api-Key: <KEY>" http://localhost:9082/httpbun/get  # 200
# <KEY>: plaintext in postgres `keys` table
# (kubectl exec deploy/gravitee-test-postgresql -- psql -U gravitee -d gravitee -tAc "select key from keys limit 1")
# or via Portal API as admin (`GET /environments/DEFAULT/applications`, then `/subscriptions?application={appId}`)
```

### Local baseURLs (kind port-forwards)

With all ingresses disabled the chart falls back to `https://apim.example.com`, which is
unreachable from a browser. `values-local.yaml` pins reachable localhost URLs:

- `gravitee.ui.baseURL: http://localhost:8083/management` (console `constants.json`)
- `gravitee.portal.baseURL: http://localhost:8083/portal` (portal `assets/config.json`)
- `gravitee.installation.api.url: http://localhost:8083` (portal `/ui/bootstrap`; without it the portal UI ignores the ConfigMaps and calls `apim.example.com`)
- `gravitee.api.env` pins `PORTAL_ENTRYPOINT` (resolves to Gravitee's `portal.entrypoint` — the gateway URL shown in try-out commands); the chart's auto value drops the `:8080` port and doubles the `/httpbun` path, and containerd drops env names containing dots

Forward `8083:83` (api), `9082:82` (gateway), `8085:8003` (portal), `8084:8002` (console).
`values.yaml` (prod) stays free of localhost.

### Secrets (env map + kubernetes:// URIs)

All secret values come from the single `env` values map: the wrapper renders
every key into a `<release>-env` Secret (`templates/env-secret.yaml`), and
Gravitee reads what it needs at boot via
`kubernetes://<ns>/secrets/<release>-env/<KEY>` URIs in gravitee.yml (see the
upstream helm chart README, "Configuration"). The chart's managed service
account (`apim.managedServiceAccount`) already grants secrets get/list, so no
secret is ever rendered in plaintext into a ConfigMap. Required keys (guarded
at render time): `POSTGRES_PASSWORD` (bundled postgres + jdbc; only applied on
first boot — rotate via PVC wipe or `ALTER USER`), `JWT_SECRET` (session
signing; the chart default is public), `ADMIN_PASSWORD` (console admin login).

No default-credential users: the memory provider has a single `admin` user
whose password comes from `env.ADMIN_PASSWORD` (`password-encoding-algo:
none`), and the chart-default demo users (`user`, `api1`, `application1`) are
dropped (`gravitee.extraInMemoryUsers: ""`). The init job authenticates with
the same secret (no admin/admin fallback).

`deploy.sh` loads `values.secret.yaml` (git-ignored, create it from
`values.secret.example.yaml`) and falls back to the example when the real file
is absent. The CI path (`.github/workflows/test.yml`) maps the
`POSTGRES_PASSWORD` / `JWT_SECRET` / `ADMIN_PASSWORD` GitHub secrets into the
step environment, which lands in `.Values.env` the same way.

### Console demo (screenshots in `docs/screenshots/`)

`01-login.png`, `02-api-detail.png` (httpbun PoC API), `03-application.png` (app-1),
`04-subscription.png`, `05-key-1.png` (app-1 key), `06-key-2.png` (app-2 key)
(viewport 1280x800, login `admin` + `env.ADMIN_PASSWORD`). Shot on the postgres/JDBC
stack with env-based secrets; gateway proof during the shoot: no key 401, key-1 200,
key-2 200, bad key 401.

## Publishing
Tag `v*` triggers `.github/workflows/helm-release.yml` -> `oci://ghcr.io/<owner>/helm-charts`.

## AppFlow note
If adding `VSHNPostgreSQL`/`VSHNMongoDB` AppCat resource later (like `litellm/templates/vshnpostgresql.yaml`), apply CR before first Helm install — Helm installs deps before wrapper manifests.

## Ponytail
Kept 4 templates + 1 job. Skipped: custom gravitee.yml mount (use `gravitee.api.configuration`), extra Secrets/PDBs, HA postgres. Add when measured.

## Deploy to test (CI)
Every push runs `.github/workflows/test.yml` (`environment: test`): `helm diff`
preview + `helm upgrade --install` of fixed release `gravitee-test` into the
namespace from the `KUBECONFIG_TEST` kubeconfig context. Manual dispatch runs
`.github/workflows/test-stop.yml`, which uninstalls it (shared
release reset). Requires the `KUBECONFIG_TEST` secret on the `test` environment.
`values-local.yaml` is never used in CI.

## Kind
Local kind users run `./deploy.sh` (fixed release `gravitee-test`, namespace
`vshn-api-gateway-gravitee-test`): single `helm upgrade --install` (bundled
postgres needs no manual first-boot step), then shows pods/svc + init log.

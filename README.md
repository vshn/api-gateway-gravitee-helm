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
Post-install hook `templates/init-job.yaml` (like `setup-api.sh` but API_KEY not KEY_LESS). Guarded by `httpbun.enabled && initJob.enabled` — disable both together. Idempotent: reuses API/plan/app if exists, publishes plan (`validation: AUTO` so no admin approval), starts API, publishes it to the catalog (`lifecycleState: PUBLISHED` + `visibility: PUBLIC` via full-body v2 PUT — otherwise the portal catalog shows nothing), waits 6s for gateway sync. Creates 3 apps/subs (`app-1..app-N`, `initJob.apiKeys=3`) via Portal API with `AUTO` validation — no admin needed; fetch keys via Portal `GET /environments/DEFAULT/subscriptions?application={appId}` (or Management API equivalent).

Unauthorized `curl http://gateway/httpbun/get` -> `401` from gateway, never hits httpbun.

## Deploy (APPUiO)
Fixed release name `gravitee-test` (like litellm) so names are predictable (`gravitee-test-gateway`, `gravitee-test-init`, ...) in namespace `vshn-api-gateway-gravitee-test`.
```sh
helm dependency update .
# -f values.secret.yaml (git-ignored) falls back to values.secret.example.yaml, as in deploy.sh/test.yml
helm upgrade --install gravitee-test . -n vshn-api-gateway-gravitee-test --create-namespace -f values.yaml -f values.secret.yaml
# httpbun disabled:
helm upgrade --install gravitee-test . --set httpbun.enabled=false --set initJob.enabled=false -f values.secret.yaml
```

## Local kind test

Bundled Bitnami Mongo fails on kind (`mkdir: cannot create directory '/bitnami/mongodb': Permission denied`). `values-local.yaml` disables it (`gravitee.mongodb.enabled=false`, `gravitee.mongo.rsEnabled=false`) and expects external `gravitee-mongodb` Service (`mongo:6.0 --noauth`).

```sh
# kind install + cluster
curl -Lo /tmp/kind https://kind.sigs.k8s.io/dl/v0.28.0/kind-linux-amd64 && chmod +x /tmp/kind && sudo mv /tmp/kind /usr/local/bin/kind
kind create cluster --name gravitee-test
kubectl cluster-info --context kind-gravitee-test

# ingress-nginx (single-host path routing; controller must listen on 8080 so
# MAPI-built absolute links carry :8080 — see "Ingress setup" below)
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl patch deploy ingress-nginx-controller -n ingress-nginx --type json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--http-port=8080"}]'
kubectl patch svc ingress-nginx-controller -n ingress-nginx --type json \
  -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":8080}]'

# deploy (fixed release `gravitee-test`): --local adds values-local.yaml and runs
# the two-phase flow (phase A hook off, rs.initiate, phase B hook on); --create-ns
# lets helm create the namespace; --diff renders/diffs only
./deploy.sh --local --create-ns   # kind
./deploy.sh                       # APPUiO
./deploy.sh --diff --local        # diff only, no cluster changes
                                  # requires: helm plugin install https://github.com/databus23/helm-diff --verify=false
                                  # exit 0 = no differences, exit 1 = differences found
kubectl get pods -n vshn-api-gateway-gravitee-test
kubectl get ingress -n vshn-api-gateway-gravitee-test
```

### Ingress setup (single host, path routing)

`values-local.yaml` enables all five ingresses on one host (`gravitee.local.test`,
`ingressClassName: nginx`) — mirrors the prod single-host path layout. Longest-prefix
match keeps them apart:

| Path         | Service                        | What                          |
|--------------|--------------------------------|-------------------------------|
| `/`          | `gravitee-test-portal:8003`    | Developer portal UI (SPA)     |
| `/portal`    | `gravitee-test-api:83`         | Portal REST API (MAPI)        |
| `/management`| `gravitee-test-api:83`         | Management/Console API (MAPI) |
| `/console`   | `gravitee-test-ui:8002`        | Console UI (prefix rewritten) |
| `/httpbun`   | `gravitee-test-gateway:82`     | Gateway (httpbun demo API)    |

# verify gateway (401 without key, 200 with key from initJob logs)
kubectl port-forward -n vshn-api-gateway-gravitee-test svc/gravitee-test-gateway 9082:82 &
curl -s http://localhost:9082/httpbun/get  # 401
curl -H "X-Gravitee-Api-Key: <KEY>" http://localhost:9082/httpbun/get  # 200
# <KEY> from: kubectl logs -n vshn-api-gateway-gravitee-test job/gravitee-test-init  OR  kubectl get secret my-gravitee-init-keys -n gravitee -o jsonpath='{.data}' | jq
```

Note: v1 `GET /management/user` (no org prefix) returns 500 `findById(null)` — dead v1
route, UIs don't use it; don't use it in scripts. Use
`/management/organizations/DEFAULT/user`.

### Verify through the ingress

```sh
B=http://gravitee.local.test:8080
curl $B/                                  # 200 portal UI HTML
curl -u admin:admin $B/management/organizations/DEFAULT/user   # 200
curl $B/console                           # 200 console UI
curl $B/httpbun/get                       # 401 without key
curl -H "X-Gravitee-Api-Key: <KEY>" $B/httpbun/get             # 200 with key
```

`<KEY>` via management API as admin: list subscriptions
(`GET /management/v2/organizations/DEFAULT/environments/DEFAULT/apis` →
`.../apis/{apiId}/subscriptions`), then
`GET .../apis/{apiId}/subscriptions/{subId}/api-keys`.

### Secrets (kind test path)

Mongo credentials are not committed: `deploy.sh` loads `values.secret.yaml`
(git-ignored, create it from `values.secret.example.yaml`) and falls back to
the example when the real file is absent. It feeds three keys:

- `mongodb.env.MONGODB_ROOT_PASSWORD` — rendered into the `mongodb-env` Secret by the vendored chart. The StatefulSet `envFrom`s that Secret; on first boot the mongo entrypoint uses `MONGO_INITDB_ROOT_PASSWORD` (the chart sets it to the same value) to provision the `root` user with it.
- `MONGODB_REPLICA_SET_KEY` — internal auth between replica-set members (`--keyFile`).
- `gravitee.mongo.auth.password` — how Gravitee learns the password: the upstream apim chart renders it **in plaintext** into the `gravitee.yml` ConfigMap. There is no Secret bridge on the Gravitee side, so both sides just carry the same literal value (`gravitee-kind-root` in the example); change it in both places together.

The CI/test path uses the same authenticated vendored mongo: `values.yaml`
enables it with replica set `mongodb-nunki` and `mongo.auth`, and
`.github/workflows/test.yml` layers `values.secret.example.yaml` on top of
`values.yaml` — the same fallback `deploy.sh` uses when the real
`values.secret.yaml` is absent.

### Credentials (kind-local throwaways)

| Credential | Value | Provenance |
|---|---|---|
| Console admin | `admin` / `admin` | apim chart default memory provider (upstream `gravitee.yml` bcrypt default) |
| Portal demo user | `demo-keys@example.com` / `Demo1234!` | registered via portal REST (`POST /portal/environments/DEFAULT/users/registration`), then BCrypt hash set via `mongosh` on `mongodb-0` (no SMTP in kind, so registration ignores the password) — recreated after every teardown |
| Mongo root password | `values.secret.yaml` | git-ignored overlay; provisions root on FIRST boot via `MONGO_INITDB_ROOT_PASSWORD` |
| API keys | (generated) | generated by Gravitee on subscription (API_KEY plan, `validation: AUTO`), fetched via management API as admin |

### Portal demo walkthrough (screenshots in `docs/screenshots/`)

Through the ingress (`gravitee.local.test:8080`), portal user `demo-keys@example.com`:
`07-ingress-login.png` (portal home), `08-ingress-api-detail.png` (httpbun PoC API),
`09-ingress-application.png` (`ingress-app-1`), `10-ingress-subscription.png`
(subscription `Accepted`, plan AUTO), `11-ingress-key-1.png` (key revealed),
`12-ingress-console.png` (console at `/console` as `admin`/`admin`). Earlier port-forward
shots (`01`–`06`, `demo@example.com`) predate the ingress setup; their subscriptions were
closed, pictured keys return 401. Gateway proof during the ingress shoot: no key 401,
key 200 (through `/httpbun`).

Note: the `httpbun PoC API` needs lifecycleState PUBLISHED + visibility PUBLIC to appear
in the portal catalog — the init job now does this (see "Init behaviour").

## Publishing
Tag `v*` triggers `.github/workflows/helm-release.yml` -> `oci://ghcr.io/<owner>/helm-charts`.

## AppFlow note
If adding `VSHNPostgreSQL`/`VSHNMongoDB` AppCat resource later (like `litellm/templates/vshnpostgresql.yaml`), apply CR before first Helm install — Helm installs deps before wrapper manifests.

## Ponytail
Kept 3 templates + 1 job. Skipped: custom gravitee.yml mount (use `gravitee.api.configuration`), extra Secrets/PDBs. Add when measured.

## Deploy to test (CI)
Every push runs `.github/workflows/test.yml` (`environment: test`): `helm diff`
preview + `helm upgrade --install` of fixed release `gravitee-test` into the
namespace from the `KUBECONFIG_TEST` kubeconfig context. Manual dispatch runs
`.github/workflows/test-stop.yml`, which uninstalls it (shared
release reset). Requires the `KUBECONFIG_TEST` secret on the `test` environment.
`values-local.yaml` is never used in CI.

## Kind
Local kind users run `./deploy.sh` (fixed release `gravitee-test`, namespace
`vshn-api-gateway-gravitee-test`): phase A installs with the init hook off, initiates the mongo
replica set, phase B upgrades with the hook on, then shows pods/svc + init log.

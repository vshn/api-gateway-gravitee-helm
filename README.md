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
initJob: {enabled: true, apiKeys: 3}
```

IdP: set `gravitee.oidcAuth` (clientId, tokenEndpoint etc). Not wired by default — `enabled:false`. POC ref: `management-api/gravitee.yml:549-565`.

## Init behaviour
Post-install hook `templates/init-job.yaml` (like `setup-api.sh` but API_KEY not KEY_LESS). Idempotent: reuses API/plan/app if exists, publishes plan, starts API, waits 6s for gateway sync. Creates `app-1..app-N` and subscriptions; fetch keys via Management API `GET /applications/{id}/subscriptions` or Portal.

Unauthorized `curl http://gateway/httpbun/get` -> `401` from gateway, never hits httpbun.

## Deploy
```sh
helm dependency update .
helm upgrade --install my-gravitee . -n gravitee --create-namespace -f values.yaml
# httpbun disabled:
helm upgrade --install my-gravitee . --set httpbun.enabled=false --set initJob.enabled=false
```

## Publishing
Tag `v*` triggers `.github/workflows/helm-release.yml` -> `oci://ghcr.io/<owner>/helm-charts`.

## AppFlow note
If adding `VSHNPostgreSQL`/`VSHNMongoDB` AppCat resource later (like `litellm/templates/vshnpostgresql.yaml`), apply CR before first Helm install — Helm installs deps before wrapper manifests.

## Ponytail
Kept 3 templates + 1 job. Skipped: custom gravitee.yml mount (use `gravitee.api.configuration`), extra Secrets/PDBs. Add when measured.

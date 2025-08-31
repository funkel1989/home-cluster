# Repository Guidelines

## Project Structure & Modules
- `kubernetes/`: GitOps source of truth. Apps live under `kubernetes/apps/<namespace>/<app>`; Flux config under `kubernetes/flux/{cluster,meta}`; shared bits in `kubernetes/components`.
- `talos/`: Talos cluster config, patches, and generated `clusterconfig/` artifacts.
- `bootstrap/`: Helmfile used during initial app bootstrap.
- `scripts/`: Bash utilities (see `scripts/bootstrap-apps.sh`).
- `Taskfile.yaml` and `.taskfiles/`: Task runners that wrap common workflows.
- `.mise.toml`: Toolchain pinning (kubectl, flux, talhelper, helmfile, task, etc.).

## Build, Test, Dev Commands
- `mise install`: Install pinned CLI tools locally.
- `task reconcile`: Force Flux to sync the repo state.
- `task bootstrap:talos` / `task bootstrap:apps`: Install Talos, then core apps.
- `task talos:generate-config | apply-node IP=? | upgrade-node IP=?`: Talos admin flows.
- Validate manifests: `kubeconform -summary kubernetes/flux/cluster`.
- Local diff/test (requires Docker): `flux-local test --enable-helm --all-namespaces --path kubernetes/flux/cluster`.

## Coding Style & Naming
- Indentation from `.editorconfig`: YAML 2 spaces; Shell 4; LF line endings.
- Filenames and Kubernetes resource names: lowercase with hyphens (e.g., `kubernetes/apps/network/external-dns`).
- Secrets: use `*.sops.yaml` and encrypt with `sops --encrypt --in-place file.sops.yaml`. Do not commit plaintext secrets; keep keys in `age.key` (local).

## Testing Guidelines
- Prefer static validation first (`kubeconform`).
- For PRs, ensure Flux renders: GitHub Action “Flux Local” runs tests and posts diffs for `kubernetes/**` changes.
- Test layout: mirror app paths; include minimal, composable Kustomizations and HelmRelease values.

## Commit & Pull Request Guidelines
- Conventional Commits: `feat:`, `fix:`, `chore:`, `docs:`, `ci:`, `refactor:` with optional scope (e.g., `feat(network): expose echo internally`).
- Keep commits focused; update related `kubernetes/` and `talos/` assets together.
- PRs must include: concise description, why/what changed, screenshots or `kubectl diff`/Flux-local excerpts for impactful changes, and linked issues if applicable.
- Label PRs with appropriate `area/*` labels (see `.github/labels.yaml`).

## Security & Configuration Tips
- Never commit credentials unencrypted; verify all `./kubernetes/**/*.sops.*` are encrypted before push.
- Use environment from `.mise.toml` (`KUBECONFIG`, `SOPS_AGE_KEY_FILE`, `TALOSCONFIG`).
- For public exposure, use the `external` Gateway; keep internal-only routes on `internal`.

## App Onboarding Requirements
- Storage: use Longhorn as default. Set `storageClassName: longhorn` (manifests) or chart values like `persistence.storageClass: longhorn` (Helm). Example PVC: `spec.storageClassName: longhorn`.
- Monitoring: every app must expose Prometheus metrics and logs.
  - Metrics: expose a `/metrics` endpoint and add a `ServiceMonitor` targeting the metrics port (e.g., name it `http-metrics`).
  - Logs: stdout/stderr are scraped by Promtail to Loki; for non-standard logs, add scrape config under `kubernetes/apps/monitoring/promtail`.
- Public access: any app on the `external` Gateway must be protected by Authentik (OIDC/OAuth2 or forward-auth/outpost). Do not expose unauthenticated endpoints; provision a client in Authentik and configure the app or its proxy accordingly.

### Copy/Paste Examples
PVC (Longhorn):
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data-myapp
  namespace: myns
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: longhorn
  resources:
    requests:
      storage: 10Gi
```

ServiceMonitor (Prometheus Operator):
```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: myapp
  namespace: monitoring
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: myapp
  namespaceSelector:
    matchNames: ["myns"]
  endpoints:
    - port: http-metrics
      path: /metrics
      interval: 30s
```
Note: ensure your Service exposes a port named `http-metrics` that points to the app’s metrics endpoint.

Service exposing metrics port:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: myapp
  namespace: myns
  labels:
    app.kubernetes.io/name: myapp
spec:
  selector:
    app.kubernetes.io/name: myapp
  ports:
    - name: http
      port: 80
      targetPort: http       # containerPort name
    - name: http-metrics
      port: 9090
      targetPort: metrics    # containerPort name
```

Helm values (common pattern):
```yaml
# Enable ServiceMonitor when supported by the chart
serviceMonitor:
  enabled: true
  namespace: monitoring
  endpoints:
    - port: http-metrics
      path: /metrics
      interval: 30s

# Use Longhorn for persistence when supported by the chart
persistence:
  enabled: true
  storageClass: longhorn
  size: 10Gi
```

Authentik forward-auth (Gateway API, Traefik example):
```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: authentik-forward-auth
  namespace: security
spec:
  forwardAuth:
    address: http://authentik-outpost.security.svc.cluster.local/outpost.goauthentik.io/auth/traefik
    trustForwardHeader: true
    authResponseHeaders:
      - X-Auth-Request-User
      - X-Auth-Request-Email
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: myapp
  namespace: myns
spec:
  hostnames: ["myapp.${SECRET_DOMAIN}"]
  parentRefs:
    - name: external
      namespace: kube-system
      sectionName: https
  rules:
    - filters:
        - type: ExtensionRef
          extensionRef:
            group: traefik.io
            kind: Middleware
            name: authentik-forward-auth
            namespace: security
      backendRefs:
        - name: myapp
          port: 80
```
Note: forward-auth configuration depends on your Gateway implementation; adjust CRDs and references accordingly.

Helm OIDC (generic pattern for apps with OIDC support):
```yaml
oidc:
  enabled: true
  issuerURL: https://auth.${SECRET_DOMAIN}/application/o/
  clientID: ${CLIENT_ID}
  clientSecret: ${CLIENT_SECRET}
  scopes: ["openid", "profile", "email"]
  redirectURI: https://myapp.${SECRET_DOMAIN}/oauth2/callback
# Some charts use a different structure, e.g.:
auth:
  generic_oauth:
    enabled: true
    client_id: ${CLIENT_ID}
    client_secret: ${CLIENT_SECRET}
    auth_url: https://auth.${SECRET_DOMAIN}/application/o/authorize/
    token_url: https://auth.${SECRET_DOMAIN}/application/o/token/
    api_url: https://auth.${SECRET_DOMAIN}/application/o/userinfo/
    scopes: openid profile email
```

# SIPMediaGW on Kubernetes

Helmfile-based deployment of [Renater/SIPMediaGW](https://github.com/Renater/SIPMediaGW)
for a Kubernetes cluster: SIP room devices dial in over PSTN (Twilio) and bridge
into Nextcloud Talk rooms.

This repo holds only non-secret configuration plus two workflows: one builds
the images, one deploys the stack to the cluster. All credentials live in
GitHub Actions secrets and Kubernetes Secrets referenced by the chart via
`existingSecret` — nothing sensitive is committed here.

## Architecture at a glance

| Component        | Choice                                                                  |
| ---------------- | ----------------------------------------------------------------------- |
| Gateway images   | Built **as-is** from upstream rev `cc280366` (no overlay). Workflow: `.github/workflows/build-images.yaml` → `ghcr.io/gliax/sipmediagw`, `ghcr.io/gliax/kamailio4sipmediagw` |
| Kamailio + MySQL | In-cluster; SIP registration + gateway dispatch (upstream logic, unmodified) |
| Public SIP entry | Dedicated LoadBalancer (TCP 5060) — `sip.example.org` points at its IP |
| Gateways         | Static StatefulSet replicas (no HTTPLauncher / proxyAPI / pairing)       |
| Media (RTP)      | Outbound via existing coturn `turn.example.org:3478` (Nextcloud Talk TURN) — no inbound RTP ports needed |
| Homer            | In-cluster: timescaledb + heplify-server + webapp (SIP capture, optional) |
| Node placement   | `doks.digitalocean.com/node-pool: gateway-nodes`; a privileged DaemonSet loads `snd-aloop` + `v4l2loopback` on those nodes |
| Renater entry point | Upstream `deploy/docker-compose.yml` + `.env` — chart variables mirror the upstream env names (secret-sourced keys excepted) |

## Repo layout

```
.
├── helmfile.yaml.gotmpl              # Release declaration (local chart); .gotmpl
│                                     # because helmfile v1 evaluates templates only there
├── chart/
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/
│       ├── gateway-configmap.yaml    # Gateway env (upstream .env equivalents; secrets come from Secrets)
│       ├── gateway-statefulset.yaml  # Static gateways; per-ordinal /dev/videoN via subPathExpr
│       ├── modules-daemonset.yaml    # Loads snd-aloop/v4l2loopback on pool nodes (8 video + 16 audio devices)
│       ├── kamailio-deployment.yaml
│       ├── kamailio-service.yaml     # LoadBalancer, TCP 5060
│       ├── mysql-statefulset.yaml
│       └── homer.yaml                # timescale + heplify-server + webapp
├── scripts/
│   └── bootstrap-secrets.sh          # Creates the 4 Secrets from env vars
├── .github/workflows/
│   ├── build-images.yaml             # CI: builds + pushes both images to GHCR
│   └── deploy.yaml                   # CD: bootstrap Secrets + helmfile apply
```

## Prerequisites

- `kubectl` with a kubecontext pointing at the target Kubernetes cluster
- `helm` v3 and `helmfile`
- A node pool labeled `doks.digitalocean.com/node-pool: gateway-nodes` (or adjust
  `gateway.nodeSelector`); kernel modules are handled
  by the DaemonSet, but nodes need `linux-modules-extra-$(uname -r)` available
  (stock Ubuntu node images have it)
- GHCR packages `ghcr.io/gliax/sipmediagw` and `ghcr.io/gliax/kamailio4sipmediagw`
  (public, or set `global.imagePullSecrets` if kept private)

## CI / CD

Two workflows, both triggered on push (they only run when their own files
change for CI; CD also chains off CI):

- **`build-images.yaml`** (CI) — checks out Renater/SIPMediaGW at the pinned
  rev, builds both images with **zero patches**, pushes them to GHCR under
  `gliax/`. To move to a newer upstream rev:
  1. Update `UPSTREAM_REV` in the workflow and `upstream.rev` + `appVersion`
     in `chart/values.yaml` / `Chart.yaml` (keep the three in sync — the tag
     equals the rev).
  2. Push; the build runs, then deploy fires automatically.

- **`deploy.yaml`** (CD) — after every successful build, and on demand via
  its "Run workflow" button: writes the site values overlay from the
  `GLIA_VALUES_YAML` secret, fetches a short-lived DOKS kubeconfig with
  `doctl`, recreates the 4 k8s Secrets via `bootstrap-secrets.sh`, and runs
  `helmfile apply`. Site values therefore never live in any repo — update
  them from the workstation with
  `gh secret set GLIA_VALUES_YAML < values-glia.yaml`.

### Required GitHub secrets

| Secret | Contents |
| ------ | -------- |
| `GLIA_VALUES_YAML` | full text of the private site values overlay |
| `SIP_SECRET` | shared gateway/kamailio SIP registration password |
| `TURN_USER` / `TURN_PASS` | coturn credentials at `turn.example.org` |
| `MYSQL_ROOT_PASSWORD` | kamailio DB root password |
| `POSTGRES_USER` / `POSTGRES_PASSWORD` | homer DB credentials |
| `DIGITALOCEAN_ACCESS_TOKEN` | DO API token (kubeconfig exchange only) |
| `DOKS_CLUSTER_NAME` | DOKS cluster name |

## First-time deploy

```sh
# 1. Push the repo: build-images runs, then deploy fires automatically
#    (DIGITALOCEAN_ACCESS_TOKEN must be set for the deploy job to reach the
#    cluster; the six credential secrets feed bootstrap-secrets.sh)

# 2. One-time DNS: after the first apply, create the A record for
#    sip.example.org (see below), then re-run the deploy workflow
```

### Public SIP entry (one-time DNS setup)

kamailio advertises a DNS name — never a raw IP — in Via/Record-Route
headers, so an LB IP change only ever touches the A record.

- Get the LB external IP: `kubectl -n sipmediagw get svc sipmediagw-kamailio`
- Create DNS A record: `sip.example.org` → that IP.
- Set `kamailio.publicAddress` to that DNS name in the site values overlay
  (the `GLIA_VALUES_YAML` Actions secret — update it from the workstation:
  `gh secret set GLIA_VALUES_YAML < values-glia.yaml`), then re-run the
  deploy workflow.
- Point Twilio at `sip:<room-token>@sip.example.org`.

The A record must resolve before the kamailio pod starts; if it doesn't,
kamailio starts anyway with a startup warning — fix DNS and restart the pod.

## Day-to-day operations

Deploys are driven from GitHub: push to rebuild/redeploy, or update the
site values with `gh secret set GLIA_VALUES_YAML < values-glia.yaml` and hit
"Run workflow" on `deploy.yaml`. Inspect from the workstation with kubectl:

```sh
kubectl -n sipmediagw get pods -o wide
kubectl -n sipmediagw logs -l app.kubernetes.io/component=gateway --tail=100
```

### Kamailio DB backup

The mysql PVC (`sipmediagw-mysql`) holds the single source of registration
state (SIP accounts, location table). Recovery = fresh PVC + restore:

```sh
kubectl -n sipmediagw exec sipmediagw-mysql-0 -- \
  sh -c 'mysqldump -p"$MYSQL_ROOT_PASSWORD" kamailio' > kamailio-backup.sql
```

Restore on a new volume:
`kubectl exec -i sipmediagw-mysql-0 -- sh -c 'mysql -p"$MYSQL_ROOT_PASSWORD" kamailio' < kamailio-backup.sql`,
then restart kamailio. The gateway pods re-register on their own.

Gateway SIP accounts register as `<GW_NAME_PREFIX>.<pod-index>` (default
`mediagw.0`, `mediagw.1`, …) against the in-cluster kamailio; kamailio routes
inbound PSTN INVITEs to an unlocked gateway with the upstream dispatch logic.

### Scaling gateways (concurrent calls)

One gateway pod = one call bridge (4 CPU / 4Gi requested). Gateways co-locate
up to node resources — an 8-vCPU node fits 2, a 16-vCPU node fits 4 — with a
soft anti-affinity spreading them across the pool. Each pod ordinal `N` binds
the node's `/dev/videoN` as its `/dev/video0` and ALSA cards `2N`/`2N+1`, so
every node (via the modules DaemonSet) provisions 8 video devices + 16
loopback cards: **up to 8 gateways per node, `replicaCount` capped at 8**
(enforced at `helmfile template`/`apply` time). Ordinals are unique per
cluster, so two pods can never claim the same device regardless of placement.

To scale: set `gateway.replicaCount: N` in your site values, `helmfile apply`.
Past 8, raise the DaemonSet's module options (`devices=`, `enable=` counts)
and `gateway.deviceCeiling` to match — the DS rewrites module configs and
reloads on its next pod start (nodes that already ran the old options need a
reboot or manual modprobe to pick up more devices).

## Deliberately not deployed

- **proxyAPI + HTTPLauncher** (pairing/QR guest join): driven by docker CLI
  calls that cannot run on k8s; unused in the DID→Talk flow. Static gateways
  instead. Revisit if ad-hoc meeting pairing is ever needed.
- **scaler**: Outscale VM autoscaler — meaningless on Kubernetes.
- **coturn**: replaced by the existing `turn.example.org` TURN.
- **TLS for SIP** (`TLS=True` upstream): kamailio would need certs + port 5061
  on the LB; upstream default in the VM setup was effectively disabled. Revisit
  if the SIP trunk requires it.

## License

Internal infrastructure config. Not distributed.

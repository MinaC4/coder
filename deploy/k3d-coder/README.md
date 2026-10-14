# Run Coder on the local k3d cluster

This deployment runs the current repository source on the existing
`k3d-openchoreo` cluster. It uses one Coder pod and one PostgreSQL pod, with
bounded requests that leave room for the cluster's existing services and a few
workspaces.

## Deploy

Run the installer from the repository root. It builds the web interface and
current source as a Linux image, imports it into k3d, provisions persistent
storage, and installs the chart:

```sh
CODER_LAN_IP="$(ipconfig getifaddr en0)" ./deploy/k3d-coder/deploy.sh
```

The host IP defaults to the current `en0` address. Set `CODER_LAN_IP` manually
if the cluster is reached through another interface. Reserve that address in
the router's DHCP settings so the saved Coder URL remains stable.

Open the printed URL from a device on the same LAN and create the initial user.
That first user becomes the deployment owner. The chart disables the default
GitHub OAuth provider and configures no model provider or local AI service.
AI features remain available to configure later with an external provider.

When creating a template for this deployment, choose the Kubernetes base
template. The Docker Containers base requires access to a Docker Engine, which
this Kubernetes provisioner does not provide. The template builder route allows
up to three minutes for imports that fetch Terraform modules or providers.

The existing Gateway serves Coder over HTTP on port `18080`; workspace app
subdomains use the same port. Keep this address on a trusted private LAN. This
k3d cluster has no public ingress or internet-facing DNS configuration.

## Persistence and restart behavior

PostgreSQL stores users, templates, workspace records, and deployment
configuration in an 8 GiB PVC. A daily `pg_dump` CronJob keeps two weeks of
backups in a separate 2 GiB PVC. Both PVCs use the cluster's `local-path`
storage. The Coder and PostgreSQL workloads restart under Kubernetes, and the
k3d containers use Docker's `unless-stopped` restart policy, so they return when
Docker Desktop starts after a computer reboot. Keep Docker Desktop's
start-on-login setting enabled.

These volumes survive a computer restart and container restart. They are on the
same computer, so copy `/backups` off-device periodically if you need recovery
after disk loss. Do not delete the `coder` namespace or its PVCs when removing
or upgrading the release.

The `coder-workspaces` namespace limits workspace pods to 8 GiB of memory,
8 CPU cores, 12 pods, and 20 GiB of persistent volumes. The cluster currently
has 12 CPU cores and 20 GiB RAM total; these limits keep workspace growth from
crowding out existing services.

## Upgrade after changing the source

Rebuild the versioned image tag and run the deploy command again. The script
imports the new image into k3d and performs a Helm upgrade while preserving the
PostgreSQL data and backups.

## Restore a database backup

Copy a dump from the `coder-postgres-backups` PVC, stop Coder, restore it into
the PostgreSQL pod with `pg_restore --clean --if-exists --no-owner`, then start
Coder again. Keep an off-device copy for disaster recovery; the cluster's local
storage alone protects against restarts, not loss of the computer or its disk.

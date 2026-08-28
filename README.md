# ai-observer-role-openstack

Policy override baseline for a read-only OpenStack role named `ai_observer`.
The role is intended for AI-assisted operations, troubleshooting, and audit-style
inspection in Charmed OpenStack environments running OpenStack Caracal
`2024.1`.

## Purpose

This repository provides:

- Charmed OpenStack `policyd-override` inputs for core OpenStack services.
- A custom `ai_observer` role model for broad read visibility.
- Guardrails that prevent `ai_observer` from matching legacy owner/member write
  policies.
- Smoke and regression scripts for validating read access and mutation denial.

The target outcome is a read-only operational identity. Do not grant this
identity `admin`, `member`, or service-specific write/admin roles.

## Scope

Generated policy override archives are provided for:

- Keystone
- Nova
- Neutron
- Cinder
- Glance
- Octavia

Placement is intentionally not packaged by this repository. Validate Placement
policy override support for the target charm revision before adding it.

## Role Model

Create the custom role and imply the standard `reader` role:

```bash
source admin-openrc

openstack role create ai_observer
openstack implied role create --implied-role reader ai_observer
```

The implied role is important because some Caracal policies check `role:reader`
directly instead of using reusable reader rules.

A single user can hold `ai_observer` assignments on multiple scopes. Each issued
token still has exactly one effective scope, so use separate RC files for
project-scoped and system-scoped operations.

Example assignments:

```bash
openstack user create --password 'CHANGE_ME' ai-observer

openstack role add \
  --user-domain Default \
  --user ai-observer \
  --system all \
  ai_observer

openstack role add \
  --user-domain Default \
  --user ai-observer \
  --project admin \
  ai_observer
```

Repeat project assignments for each project that must be visible:

```bash
for project in $(openstack project list -f value -c ID); do
  openstack role add \
    --user-domain Default \
    --user ai-observer \
    --project "$project" \
    ai_observer || true
done
```

## Build Overrides

Run commands from the repository root:

```bash
chmod +x scripts/build-policyd-override.sh
./scripts/build-policyd-override.sh
```

The build creates:

- `dist/keystone-policyd-override.zip`
- `dist/nova-policyd-override.zip`
- `dist/neutron-policyd-override.zip`
- `dist/cinder-policyd-override.zip`
- `dist/glance-policyd-override.zip`
- `dist/octavia-policyd-override.zip`

Rebuild after changing any file under `overrides/`, then reattach the affected
archive to the corresponding Juju application.

## Apply Overrides

Use the application names from the target Juju model. Common names are shown
below:

```bash
juju attach-resource keystone policyd-override=dist/keystone-policyd-override.zip
juju config keystone use-policyd-override=true

juju attach-resource nova-cloud-controller policyd-override=dist/nova-policyd-override.zip
juju config nova-cloud-controller use-policyd-override=true

juju attach-resource neutron-api policyd-override=dist/neutron-policyd-override.zip
juju config neutron-api use-policyd-override=true

juju attach-resource cinder policyd-override=dist/cinder-policyd-override.zip
juju config cinder use-policyd-override=true

juju attach-resource glance policyd-override=dist/glance-policyd-override.zip
juju config glance use-policyd-override=true

juju attach-resource octavia policyd-override=dist/octavia-policyd-override.zip
juju config octavia use-policyd-override=true
```

Confirm that overrides are enabled:

```bash
for app in keystone nova-cloud-controller neutron-api cinder glance octavia; do
  printf "%-24s " "$app"
  juju config "$app" use-policyd-override
done
```

## RC File Examples

Project-scoped RC file:

```bash
export OS_AUTH_URL=https://keystone.example.com:5000/v3
export OS_USERNAME=ai-observer
export OS_PASSWORD=CHANGE_ME
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_ID=<admin-project-id-used-by-nova-policy>
export OS_IDENTITY_API_VERSION=3
unset OS_PROJECT_NAME
unset OS_PROJECT_DOMAIN_NAME
unset OS_SYSTEM_SCOPE
```

System-scoped RC file:

```bash
export OS_AUTH_URL=https://keystone.example.com:5000/v3
export OS_USERNAME=ai-observer
export OS_PASSWORD=CHANGE_ME
export OS_USER_DOMAIN_NAME=Default
export OS_SYSTEM_SCOPE=all
export OS_IDENTITY_API_VERSION=3
unset OS_PROJECT_ID
unset OS_PROJECT_NAME
unset OS_PROJECT_DOMAIN_NAME
```

Use project scope for project-visible resources and Nova deployment-wide reads
that are still project-scoped by Nova policy:

```bash
source ai-observer-openrc
openstack token issue
openstack network list
openstack image list
openstack loadbalancer list
openstack server list --all-projects
openstack hypervisor list
openstack compute service list
```

Use system scope for services and APIs that support system-scoped reads:

```bash
source ai-observer-system-openrc
openstack token issue
openstack volume list --all-projects
```

Some Nova Caracal deployment-wide read APIs are still project-scoped by policy.
For those APIs, use an admin-project-scoped token combined with the read-only
`ai_observer` policy rules instead of assigning the user the `admin` role.
In environments with multiple projects named `admin`, use `OS_PROJECT_ID`
instead of `OS_PROJECT_NAME` to avoid selecting the wrong project.

Example Nova deployment-wide reads:

```bash
source ai-observer-openrc
openstack token issue
openstack server list --all-projects
openstack hypervisor list
openstack compute service list
```

## Validation

Run static validation without OpenStack credentials:

```bash
./scripts/validate-policy-overrides.py
```

Run the role audit with an admin-scoped shell:

```bash
source admin-openrc
./scripts/audit-ai-observer-user.sh ai-observer Default
```

Run read and mutation smoke tests:

```bash
./scripts/smoke-read-access.sh ai-observer-openrc ai-observer-system-openrc
./scripts/smoke-mutation-denied.sh ai-observer-openrc ai-observer-system-openrc
```

Run the bundled test wrapper:

```bash
source admin-openrc
./scripts/run-ai-observer-tests.sh \
  ai-observer-openrc \
  ai-observer-system-openrc \
  ai-observer \
  Default
```

For deeper mutation regression coverage, including Cinder snapshots, metadata,
image-backed volumes, transfers, attachments, readonly/upload actions, and
selected admin-gated reads, run:

```bash
./scripts/deep-mutation-guard.sh --admin-rc admin-openrc
```

Octavia load balancer probes are included by default. To skip them:

```bash
./scripts/deep-mutation-guard.sh --admin-rc admin-openrc --skip-octavia
```

Run the deep mutation guard only in environments where temporary projects and
resources are acceptable. The script attempts cleanup, but failed service calls
or interrupted runs may require manual review.

## Manual Checks

The following actions should be denied from the AI observer RC files:

```bash
openstack server create ...
openstack server delete ...
openstack network create ...
openstack volume create ...
openstack image set ...
openstack loadbalancer create ...
```

Useful role audit:

```bash
openstack role assignment list --user ai-observer --user-domain Default --names
```

The AI observer user should only have `ai_observer` on the intended system and
project scopes. Normal application users that create or modify resources should
use standard `member` or `admin` assignments on their projects.

## Limitations

- This baseline is focused on OpenStack Caracal and Charmed OpenStack.
- Extra services such as Heat, Barbican, Magnum, Ironic, or service plugins need
  equivalent per-service policy review if deployed.
- Some sensitive read fields may require additional explicit grants depending on
  charm revision, service configuration, and enabled API extensions.
- Cinder Caracal protects host GET and host PUT with the same
  `volume_extension:hosts` rule. Host listing therefore remains denied to
  `ai_observer`; granting it would also permit host mutation.
- Cinder service, scheduler-pool, backend-capability, and QoS reads perform hard
  administrator context checks below policy authorization in Caracal. They
  remain denied to `ai_observer`; widening `context_is_admin` would expose
  unrelated admin APIs.
- Cinder filters group specs from aggregate group-type representations for
  non-admin contexts. The dedicated group-spec list and individual-spec GET
  endpoints remain available to `ai_observer` through separate read-only rules.
- Charmed service units may need a policy reload or service restart after a
  resource update, depending on charm behavior.

## References

- [Keystone Caracal default roles and scope model](https://docs.openstack.org/keystone/2024.1/admin/service-api-protection.html)
- [Nova Caracal policy reference](https://docs.openstack.org/nova/2024.1/configuration/policy.html)
- [Neutron Caracal policy reference](https://docs.openstack.org/neutron/2024.1/configuration/policy.html)
- [Cinder Caracal policy reference](https://docs.openstack.org/cinder/2024.1/configuration/block-storage/policy.html)
- [Glance Caracal policy source](https://opendev.org/openstack/glance/src/branch/stable/2024.1/glance/common/policies)
- [Octavia Caracal policy source](https://opendev.org/openstack/octavia/src/branch/stable/2024.1/octavia/policies)
- [Charmhub nova-cloud-controller configuration for `use-policyd-override`](https://charmhub.io/nova-cloud-controller/configurations#use-policyd-override)

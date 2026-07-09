# OpenStack Caracal AI Read-Only Role for Charmed OpenStack

This repository contains a practical policy override baseline for a custom role named ai_observer.

Goal:
- Make an AI investigation user read-only.
- Allow broad visibility across Caracal services.
- Apply through Charmed OpenStack using Juju policy override resources.

Important notes:
- In Caracal, many services already use the reader role for read APIs.
- Some services still gate sensitive read APIs behind admin checks.
- The overrides here add targeted read expansions for ai_observer and pin known legacy write aliases so ai_observer project assignments are not treated as owner/member write access.
- For rules that directly check role:reader, use Keystone role implication so ai_observer automatically satisfies reader checks.
- Do not grant the AI user admin, member, or service-specific write/admin roles.
- Existing non-AI users that need write access should have normal member or admin role assignments. These overrides intentionally stop legacy project-owner checks from granting write access to users that only have ai_observer.

## 1) Create the custom role and role implication

Source an admin RC first.

```bash
source admin-openrc

openstack role create ai_observer
openstack implied role create --implied-role reader ai_observer
```

Why implication is required:
- Some Caracal policies directly check role:reader instead of reusable reader rules.
- Implication avoids per-endpoint edits for every one of those direct checks.

## 2) Build the Juju policyd override ZIP files

```bash
cd /home/kbhaskar/git/openstack-custom-role
chmod +x scripts/build-policyd-override.sh
./scripts/build-policyd-override.sh
```

This creates:
- dist/keystone-policyd-override.zip
- dist/nova-policyd-override.zip
- dist/neutron-policyd-override.zip
- dist/cinder-policyd-override.zip
- dist/glance-policyd-override.zip
- dist/octavia-policyd-override.zip

Re-run this script after any override change, then reattach the affected ZIP files to the relevant Juju applications.

## 3) Attach and enable overrides in Charmed OpenStack

Use the app names in your model. Common names are shown below.

```bash
# Keystone
juju attach-resource keystone policyd-override=dist/keystone-policyd-override.zip
juju config keystone use-policyd-override=true

# Nova API/control plane
juju attach-resource nova-cloud-controller policyd-override=dist/nova-policyd-override.zip
juju config nova-cloud-controller use-policyd-override=true

# Neutron API
juju attach-resource neutron-api policyd-override=dist/neutron-policyd-override.zip
juju config neutron-api use-policyd-override=true

# Cinder API
juju attach-resource cinder policyd-override=dist/cinder-policyd-override.zip
juju config cinder use-policyd-override=true

# Glance API
juju attach-resource glance policyd-override=dist/glance-policyd-override.zip
juju config glance use-policyd-override=true

# Octavia API
juju attach-resource octavia policyd-override=dist/octavia-policyd-override.zip
juju config octavia use-policyd-override=true
```

Optional but recommended checks:

```bash
for app in keystone nova-cloud-controller neutron-api cinder glance octavia; do printf "%-24s " "$app"; juju config "$app" use-policyd-override; done
```

## 4) Create an AI user and grant read role assignments

To cover both system-scoped and project-scoped read APIs, grant both scopes.

```bash
# Example user creation
openstack user create --password 'CHANGE_ME' agent_tony_reader

# System-scope read visibility
openstack role add --user-domain default --user agent_tony_reader --system all ai_observer

# Project-scope read visibility (repeat for each project that must be visible)
openstack role add --user-domain default --user agent_tony_reader --project admin ai_observer
```

If you need visibility into all projects, automate project assignments:

```bash
for project in $(openstack project list -f value -c ID); do
  openstack role add --user-domain default --user agent_tony_reader --project "$project" ai_observer || true
done
```

## 5) Create an RC file for the AI user

Create ai-observer-openrc with your endpoint values for project-scoped reads:

```bash
export OS_AUTH_URL=https://keystone.example.com:5000/v3
export OS_USERNAME=ai-agent
export OS_PASSWORD=CHANGE_ME
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_NAME=admin
export OS_PROJECT_DOMAIN_NAME=Default
export OS_IDENTITY_API_VERSION=3
unset OS_SYSTEM_SCOPE
```

Create ai-observer-system-openrc for system-scoped reads:

```bash
export OS_AUTH_URL=https://keystone.example.com:5000/v3
export OS_USERNAME=ai-agent
export OS_PASSWORD=CHANGE_ME
export OS_USER_DOMAIN_NAME=Default
export OS_SYSTEM_SCOPE=all
export OS_IDENTITY_API_VERSION=3
unset OS_PROJECT_ID
unset OS_PROJECT_NAME
unset OS_PROJECT_DOMAIN_NAME
```

Use project scope for normal project-visible resources:

```bash
source ai-observer-openrc
openstack token issue
openstack network list
openstack image list
openstack loadbalancer list
```

Use system scope for cross-project or deployment-wide read APIs:

```bash
source ai-observer-system-openrc
openstack token issue
openstack server list --all-projects
openstack volume list --all-projects
```

## 6) Validation checklist

Static checks can be run without OpenStack credentials:

```bash
./scripts/validate-policy-overrides.py
```

This verifies the override layout, generated ZIP contents, absence of Placement override packaging, and that known write policies do not grant ai_observer.

Run the role audit with an admin-scoped shell:

```bash
source admin-openrc
./scripts/audit-ai-observer-user.sh ai-agent default
```

This verifies that ai-agent has ai_observer, does not have member/admin/service write roles, and that ai_observer implies reader.

Run read and mutation smoke tests with the AI user's RC files:

```bash
./scripts/smoke-read-access.sh ai-observer-openrc ai-observer-system-openrc
./scripts/smoke-mutation-denied.sh ai-observer-openrc ai-observer-system-openrc
```

The mutation-denial script uses non-destructive probes where possible. A policy 403 is a pass. Missing services are skipped. A validation or not-found error before a policy decision is reported as inconclusive and should be investigated manually.

To run the full suite:

```bash
source admin-openrc
./scripts/run-ai-observer-tests.sh ai-observer-openrc ai-observer-system-openrc ai-agent default
```

For high-confidence create/update/delete testing, run the self-contained deep mutation guard with an admin RC. This script creates a disposable project, a disposable AI test user, a disposable non-AI member test user, grants only ai_observer to the AI user, creates temporary image/flavor/network/subnet fixtures, generates temporary project-scoped and system-scoped AI RC files, generates a temporary member RC file, attempts project-scope resource creates/updates/deletes and system-scope admin/control-plane mutations, and cleans up known test resources. It logs each created test resource and each cleanup attempt so the run can be audited afterward.

The deep guard also runs positive-control checks with the non-AI member user. Those checks must not be denied by policy; a policy denial for the member user is treated as a failure because it means the overrides are affecting normal users. A later service/backend/state error is still counted as a pass for this policy regression check because the request reached normal service validation. The admin RC is also exercised throughout fixture creation and cleanup, so admin regressions show up as setup or cleanup failures.

For the deep guard, an explicit policy denial is the only passing result for each AI mutation probe. If a request is accepted and later fails for quota, scheduling, backend, or validation reasons, that still fails the test because the policy layer did not reject the mutation.

If Octavia service roles such as load-balancer_member or load-balancer_admin exist, the script grants one to the admin fixture identity on the disposable project so it can create load balancer fixtures for update/delete tests. The disposable AI user is still granted only ai_observer.

```bash
./scripts/deep-mutation-guard.sh --admin-rc admin-openrc
```

Octavia load balancer probes are included by default. To skip them:

```bash
./scripts/deep-mutation-guard.sh --admin-rc admin-openrc --skip-octavia
```

Run the deep guard only where temporary projects and resources are safe. If any AI mutation is not denied by policy, the script reports failure and still attempts cleanup. Use `--keep-resources` only when you need to inspect a failed test environment manually.

Manual mutation checks should still fail from both AI RC files:

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
openstack role assignment list --user ai-agent --names
```

The AI user should only have ai_observer on the intended project and system scopes. It should not have member, admin, or service-specific write/admin roles.

Normal application users that should be able to create or modify resources should have member or admin assignments on their projects.

## 7) Scope and limitations

- This baseline is Caracal-focused and targets core services in charmed deployments.
- Placement is not packaged here; validate Placement policy override support separately for your charm revision before adding it.
- Plugin APIs or extra services (for example Heat, Barbican, Magnum, Ironic) need equivalent per-service overrides if deployed.
- Some highly sensitive fields may still require additional explicit read-policy grants depending on your exact charm revision and enabled API extensions.

## Reference sources used

- Keystone Caracal default roles and scope model
- Nova Caracal policy reference
- Neutron Caracal policy reference
- Cinder Caracal policy reference
- Glance Caracal policy reference
- Octavia Caracal policy reference
- Charmed OpenStack charm configuration pages for use-policyd-override

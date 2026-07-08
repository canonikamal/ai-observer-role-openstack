# Managed Asset Change Request

| Field         | Value                |
|---------------|----------------------|
| **Change Name** | Implement OpenStack Caracal ai_observer read-only policy overrides |
| **Ticket**      |   |

---

## Change Type

- [ ] **Emergency**
- [ ] **Standard Change**
  - [ ] Does not need review
  - [ ] Performed during a pre-approved standing MW
- [x] **Normal Change**
- [ ] **Investigation** - Driven by product, SEG, etc.

---

## Reason for Change

- Implement a restricted read-only OpenStack role named `ai_observer` for AI-assisted troubleshooting. The role is intended to provide broad operational visibility while preventing create, update, delete, and other mutating API actions in both project-scoped and system-scoped usage.

---

## Proposed Change

- Create or verify the Keystone role `ai_observer` and implied role mapping from `ai_observer` to `reader`.
- Apply Charmed OpenStack `policyd-override` resources for Keystone, Nova, Neutron, Cinder, Glance, and Octavia.
- Preserve and merge any existing service policy overrides before attaching the new override resources. The current Nova override rule `os_compute_api:os-extended-server-attributes: rule:admin_or_owner` is included in the proposed Nova override.
- Enable `use-policyd-override=true` on the corresponding Juju applications.
- Grant the AI troubleshooting user only the `ai_observer` role on required project scopes and `--system all`.
- Do not grant the AI troubleshooting user `member`, `admin`, service admin, or service write roles.
- Validate that `ai_observer` read access works and mutation requests are denied.
- Validate that normal `member` and `admin` users are not negatively affected by the policy overrides.

---

## Impact Statement

- Expected impact is limited to OpenStack API policy authorization.
- The AI troubleshooting user will gain read-only visibility across approved OpenStack services and scopes.
- The AI troubleshooting user should be unable to create, modify, delete, reboot, resize, attach, detach, upload, or otherwise mutate OpenStack resources.
- Existing normal users with `member` or `admin` roles should retain their current permissions.
- No compute, network, storage, image, or load balancer data-plane outage is expected.
- API policy reload or charm-managed service restart may briefly affect API availability depending on charm behavior.

---

## Action Plan

- Source an OpenStack admin RC file.
- Check current policy override enablement:
  `for app in keystone nova-cloud-controller neutron-api cinder glance octavia; do printf "%-24s " "$app"; juju config "$app" use-policyd-override; done`
- For any application where `use-policyd-override=true`, inspect the active policy override files before making changes.
- Back up the existing Nova policy override from the nova-cloud-controller leader:
  `juju ssh nova-cloud-controller/leader 'sudo tar -C /etc/nova -czf /tmp/nova-policy.d-pre-ai-observer.tgz policy.d && sudo ls -l /tmp/nova-policy.d-pre-ai-observer.tgz'`
- Copy the Nova policy backup off the unit to the operator workstation or approved change backup location:
  `juju scp nova-cloud-controller/leader:/tmp/nova-policy.d-pre-ai-observer.tgz ./nova-policy.d-pre-ai-observer.tgz`
- Verify the existing Nova rule is present in the proposed override source:
  `grep 'os_compute_api:os-extended-server-attributes' overrides/nova/ai-observer.yaml`
- Verify the `ai_observer` role exists:
  `openstack role show ai_observer`
- Create the role if it does not exist:
  `openstack role create ai_observer`
- Verify the implied role mapping from `ai_observer` to `reader`:
  `openstack implied role list`
- Create the implied role mapping if it does not exist:
  `openstack implied role create --implied-role reader ai_observer`
- Build or verify the policy override ZIP files:
  `./scripts/build-policyd-override.sh`
- Verify the Nova policy override ZIP includes the preserved existing rule:
  `unzip -p dist/nova-policyd-override.zip ai-observer.yaml | grep 'os_compute_api:os-extended-server-attributes'`
- Attach policy override ZIP files to the Juju applications:
  `keystone`, `nova-cloud-controller`, `neutron-api`, `cinder`, `glance`, and `octavia`.
- Enable policy overrides on the Juju applications using `use-policyd-override=true`.
- Verify Juju application status returns to healthy/active.
- Run static validation:
  `./scripts/validate-policy-overrides.py`
- Run read and mutation validation for the AI user.
- Run the self-contained deep mutation guard:
  `./scripts/deep-mutation-guard.sh --admin-rc admin-openrc`
- Confirm there are no failed checks and no unexpected inconclusive checks.

---

## Checkpoints

> Steps where the execution of the action plan can be paused or validated.

- Confirm `ai_observer` role and `ai_observer -> reader` implied role mapping exist before applying policy overrides.
- Confirm current `use-policyd-override` values are recorded for Keystone, Nova, Neutron, Cinder, Glance, and Octavia.
- Confirm existing active policy override files are backed up for any application that already has `use-policyd-override=true`.
- Confirm the existing Nova rule `os_compute_api:os-extended-server-attributes: rule:admin_or_owner` is included in the new Nova override ZIP.
- Confirm generated policy override ZIP files exist for Keystone, Nova, Neutron, Cinder, Glance, and Octavia.
- Confirm no Placement policy override is applied from this package; validate Placement policy override support separately for the target charm revision before adding it.
- Confirm Juju applications are healthy after attaching and enabling overrides.
- Confirm AI user can issue project-scoped and system-scoped tokens.
- Confirm AI user read-only smoke tests pass.
- Confirm AI user create/update/delete mutation tests are denied by policy.
- Confirm non-AI `member` user positive-control tests are not denied by policy.
- Confirm admin fixture creation and cleanup complete successfully.

---

## Duration of Maintenance

| Item                | Value       |
|---------------------|-------------|
| **Total duration**  | 1 hour      |
| **Rollback deadline** | 30 min    |
| **Includes health checks** | Yes  |

---

## Proposed Schedule

| Item              | Value            |
|-------------------|------------------|
| **Regional Team** | Any    |
| **Date & Time**   | To be scheduled |

---

## Monitoring During Changes

- Monitor Juju application status for Keystone, Nova, Neutron, Cinder, Glance, and Octavia.
- Monitor OpenStack API health and authentication failures.
- Monitor policy-related `HTTP 403` responses for unexpected denials affecting non-AI users.
- Monitor service logs for policy parse errors or policy load failures.
- Monitor the validation script output and cleanup results.

---

## Test Plan

- Run static policy override validation:
  `./scripts/validate-policy-overrides.py`
- Verify the AI user has only `ai_observer` assignments on intended project and system scopes.
- Verify `ai_observer` implies `reader`.
- Run read access smoke tests for project-scoped and system-scoped AI RC files.
- Run mutation denial smoke tests for AI project-scoped and system-scoped RC files.
- Run the self-contained deep mutation guard:
  `./scripts/deep-mutation-guard.sh --admin-rc admin-openrc`
- Confirm expected result: AI mutation probes are denied by policy.
- Confirm expected result: non-AI member positive-control probes are not denied by policy.
- Confirm expected result: admin setup, fixture creation, and cleanup complete successfully.
- Confirm no unintended resources remain after test cleanup.

---

## Rollback Plan

- Disable policy overrides on affected Juju applications:
  `juju config <application> use-policyd-override=false`
- For applications that did not previously use policy overrides, leave `use-policyd-override=false`.
- For applications that previously used policy overrides, reattach the backed-up policy override resource and restore the original `use-policyd-override` value. For Nova, use the backed-up `/etc/nova/policy.d` content or the previously approved Nova policyd override resource containing `os_compute_api:os-extended-server-attributes: rule:admin_or_owner`.
- Wait for Juju applications to settle back to healthy/active status.
- Re-run API health checks and representative OpenStack commands for admin and normal member users.
- Remove `ai_observer` project and system role assignments from the AI troubleshooting user if immediate access removal is required.
- Remove the `ai_observer -> reader` implied role mapping and/or delete the `ai_observer` role only after confirming no dependent assignments remain.
- Re-run validation to confirm normal user/admin access is restored and no AI read-only policy override remains active.

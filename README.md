# Power Platform governance with Terraform

Companion example for Harry Traynor's post "How far can Terraform take Power Platform governance?". Clone it and plan it against a Power Platform dev or test tenant. It is an experiment in putting tier rules, lane requests, and tenant baselines in files that Terraform can plan before anything changes.

The shape of the model (tiers, lanes, firm checks, and state split by blast radius) is inspired by Simon Owen's work at EmPOWER Your World. Credit:

- [Scalable Governance v2](https://www.empoweryour.world/blog/scalable-governance-v2)
- [Governance as Code](https://www.empoweryour.world/modellibrary/11-governance-as-code)

This repository is a smaller cut of that idea, limited to what the official `microsoft/power-platform` provider can apply today. Provider version is pinned to **4.2.1**.

Read [Security and limitations](#security-and-limitations) before you adapt this beyond a dev tenant.

## Layout

| Path | What it holds |
| --- | --- |
| `tiers/` | One YAML file per size: sandbox, small, medium, large, exception. Rules, release shape, and the data-policy connector list. |
| `lanes/` | One YAML file per lane (an environment request). Files can sit in subfolders. Two examples are included. |
| `tenant/baseline.yaml` | Tenant settings this stack will send. Omitted settings stay as they are. |
| `modules/tier-config` | Reads one tier file and emits stable outputs. |
| `modules/environment-group` | One environment group and its rule set. |
| `modules/lane` | Security group, environment, optional managed-environment settings, application user, and security role. |
| `modules/data-policy` | A block-by-default data policy scoped to specific environments. |
| `modules/tenant-baseline` | The tenant settings resource. |
| `stacks/tenant` | Tenant settings, and an optional default-environment data policy. Own state. |
| `stacks/groups` | One environment group per tier file. Own state. |
| `stacks/lanes` | One apply for one cost centre, or for `shared`. Cost centre state holds that centre's environments. `shared` holds fan-in environments and the tier data policies. |
| `examples/register-admin-application` | One-shot registration of the service principal. A person runs it. The service principal cannot register itself. |
| `examples/tenant-isolation` | Optional cross-tenant isolation policy. Separate from the tenant stack. Workflows do not apply it. |
| `scripts/` | Lane checks, the lanes state migration, a local validate script, and state-storage bootstrap. |
| `.github/workflows/` | Plan on pull request, apply on merge to `main`, nightly drift check. |

Apply order is **tenant**, then **groups**, then each **lanes** cost centre, then **lanes shared**. A bad lane plan cannot refresh the tenant stack, and a plan for one cost centre cannot refresh another's environments, because the state files are separate. The shared state runs last so its data policies see the environment ids just applied.

With `create_release_stages = false` (the default), the two example lanes produce two dev environments: `cc-0000-customer-service-dev` and `cc-0000-field-operations-dev`. The display name is `<cost centre>-<lane>-<stage>`, built in `modules/lane`. The cost centre and the lane are trimmed, lowercased, and slugified: spaces and underscores become hyphens, and repeated hyphens collapse. A blank cost centre is rejected. Names have to stay unique for each lane and stage, and validation fails when two would slugify to the same name. A shared fan-in environment uses the label `all-lanes`, for example `shared-all-lanes-test`. `name_prefix` is only used on data policy names. Provider 4.2.1 updates `display_name` in place. The Entra group's mail nickname is left as it was, because changing it would replace the group. A Developer lane does not create a lane security group. The example lanes set `dev_environment_type: Developer`; see [Developer dev environments](#developer-dev-environments). Turning the flag on also creates `shared-all-lanes-test`, `shared-all-lanes-prod`, `cc-0000-field-operations-test`, and `cc-0000-field-operations-prod`. Read that plan before you apply it.

## Prerequisites

You need:

- Terraform 1.6 or newer. The workflows pin 1.16.6.
- Azure CLI, for the local sign-in and for `scripts/bootstrap-state.sh`.
- Python 3 with PyYAML (`python3 -m pip install pyyaml`), for `scripts/check-lanes.py`.
- A Power Platform dev or test tenant with a licence that covers managed environments. Environment groups require managed environments. Each Sandbox environment with Dataverse also needs at least 1 GB of free **paid** Dataverse database capacity. Developer, viral trial, and M365 E5 developer licences add none, and the create fails with HTTP 409 `InsufficientCapacity_StorageDriven`.
- An Azure subscription for the Terraform state storage account, if you use the `azurerm` backend. A first local plan can use the local backend instead. See below.

### App registration

Create an Entra app registration and a service principal. Add these API permissions and grant admin consent. The Dynamics CRM, Power Platform API, and PowerApps Service entries are **delegated** scopes (those APIs publish no matching application roles; service principal access comes from the Power Platform admin registration below). Microsoft Graph `Group.ReadWrite.All` must be an **application** permission:

- Dynamics CRM: `user_impersonation`
- Power Platform API (`8578e004-a5c6-46e7-913e-12f58912df43`):
  - `AppManagement.ApplicationPackages.Install`
  - `AppManagement.ApplicationPackages.Read`
  - `Licensing.Allocations.ReadWrite`
  - `Licensing.BillingPolicies.ReadWrite`
  - `PowerApps.Apps.Play`
  - `PowerApps.Apps.Read`
  - `EnvironmentManagement.Environments.Read`
  - `EnvironmentManagement.Groups.ReadWrite`
  - `EnvironmentManagement.Settings.ReadWrite`
- PowerApps Service (`475226c6-020e-4fb2-8a90-7a972cbfc1d4`): `User`
- Microsoft Graph: `Group.ReadWrite.All`, application permission (the lanes stack creates Entra security groups; the provider guide does not list this permission)

If Power Platform API does not appear when you search by name, instantiate it in the tenant:

```powershell
Install-Module AzureAD
Connect-AzureAD
New-AzureADServicePrincipal -AppId 8578e004-a5c6-46e7-913e-12f58912df43 -DisplayName "Power Platform API"
```

Or with the Azure CLI (the AzureAD module is retired):

```bash
az ad sp create --id 8578e004-a5c6-46e7-913e-12f58912df43
```

For a local plan with `use_cli = true`, preauthorise the Azure CLI client application `04b07795-8ddb-461a-bbee-02f9e1bf7b46` on the app registration, as described in the provider's [app registration guide](https://registry.terraform.io/providers/microsoft/power-platform/4.2.1/docs/guides/app_registration).

Assign the Entra directory role **Power Platform Administrator** to the enterprise application.

Register that same application with Power Platform. A service principal cannot register itself. Sign in as a person who is already a Power Platform admin and run:

```bash
az login
cd examples/register-admin-application
terraform init
terraform apply -var='application_client_id=YOUR-APP-CLIENT-ID'
```

`YOUR-APP-CLIENT-ID` is the application (client) id, not the object id.

## Authentication

No secret belongs in this repository. `*.tfvars` is gitignored except `*.tfvars.example`. `backend.hcl` is gitignored.

Local plan and apply use the Azure CLI (`use_cli = true` in the example tfvars). GitHub Actions uses a federated credential (`use_oidc = true`). Leave both false only when you export a client secret yourself:

- `POWER_PLATFORM_CLIENT_SECRET` for the Power Platform provider
- `ARM_CLIENT_SECRET` for the Azure AD provider and the `azurerm` backend

The provider checks `use_cli` before `use_oidc`. Set only one of them.

## Run it locally, through the first plan

### 1. Check the YAML

```bash
python3 -m pip install pyyaml
python3 scripts/check-lanes.py
```

Firm failures exit 1. Access and complexity warnings print and exit 0. The lanes stack repeats the firm rules as Terraform preconditions, so a plan still fails closed if you skip the script.

### 2. Pick a backend

**Remote state (what CI uses).** Create the storage account first. The stacks cannot create the account that holds their own state.

```bash
az login
export AZURE_LOCATION=westeurope
export TF_STATE_RESOURCE_GROUP=rg-REPLACE-tfstate
export TF_STATE_STORAGE_ACCOUNT=streplace1234   # 3-24 lowercase letters and digits
export TF_STATE_CONTAINER=tfstate
export ASSIGNEE_OBJECT_ID=YOUR-ENTERPRISE-APP-OBJECT-ID
export USER_ASSIGNEE_OBJECT_ID=YOUR-USER-OBJECT-ID   # optional, for local CLI runs
./scripts/bootstrap-state.sh
```

`ASSIGNEE_OBJECT_ID` is the enterprise application object id. The script grants that principal **Storage Blob Data Contributor**, and grants the same role to `USER_ASSIGNEE_OBJECT_ID` when it is set. It does not delete anything. Azure enforces MFA on resource writes, so the CLI session that runs the script must be an MFA sign-in. Set `USER_ASSIGNEE_OBJECT_ID` to your own user object id: after shared keys are off, the container is created with `--auth-mode login` as you.

In each of `stacks/tenant`, `stacks/groups`, and `stacks/lanes`:

```bash
cp backend.hcl.example backend.hcl
```

Edit the three files. The keys are already `tenant.tfstate`, `groups.tfstate`, and `lanes/cc-0000.tfstate`. Fan-in environments and the tier data policies use a second lanes key, `lanes/shared.tfstate`, passed with `-backend-config=key=...` so you do not edit the file between inits. Set `use_oidc = false` for a CLI sign-in, or leave `use_oidc = true` when the Azure CLI session is itself a federated identity. Keep `use_azuread_auth = true`: the script disables shared key access, so the backend cannot fall back to account keys.

A local backend is one file. It cannot hold `lanes/cc-0000.tfstate` and `lanes/shared.tfstate` at the same time. Use the Azure Storage backend for the split. An existing `lanes.tfstate` blob has to be moved before the first apply of these keys. See [Move an existing lanes state](#move-an-existing-lanes-state).

The script hardens the account: shared key and SAS access off, TLS 1.2 minimum, HTTPS only, no public blob access, blob versioning, and 14-day blob and container soft delete (`SOFT_DELETE_DAYS`). It grants Storage Blob Data Contributor on the account, then creates the container with `--auth-mode login`, retrying for up to `RBAC_WAIT_SECONDS` (default 600) while the role propagates.

For a local run where the Power Platform and Azure AD providers sign in as the service principal with a client secret but the backend uses your CLI sign-in, leave `ARM_CLIENT_ID` unset: the backend only uses `ARM_CLIENT_SECRET` when a client id is also set. Pass the client id to the providers with `TF_VAR_client_id` instead.

**Local state (fastest first plan).** In each stack's `versions.tf`, change `backend "azurerm" {}` to `backend "local" {}`. Do not commit that edit. After you change it, `terraform init -reconfigure`.

### 3. Tenant stack: the first plan

```bash
cd stacks/tenant
cp terraform.tfvars.example terraform.tfvars
az login
terraform init -input=false -backend-config=backend.hcl
# local backend instead: terraform init -input=false -reconfigure
terraform plan
```

Leave `manage_default_environment_dlp` false for this plan. Leave `route_new_makers_to_sandbox` false as well. Routing stays off until a second tenant apply, after the groups stack exists. See [Steering makers away from the default environment](#steering-makers-away-from-the-default-environment). Cross-tenant isolation is a separate example, described under known limitations, and this plan does not touch it.

Read the plan. It changes tenant settings listed in `tenant/baseline.yaml`. Destroy later restores the values Terraform recorded at create. It does not delete the tenant.

```bash
terraform apply
```

### 4. Groups stack

```bash
cd ../groups
cp terraform.tfvars.example terraform.tfvars
terraform init -input=false -backend-config=backend.hcl
terraform plan
terraform apply
terraform output -json environment_group_ids
```

This creates five groups, named `Tier - Sandbox` through `Tier - Exception`, and applies each tier file's rule set. It does not create environments.

### 5. Lanes stack

```bash
cd ../lanes
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

- Set `pipeline_application_id` to the application (client) id that should become a Dataverse application user. The example value is a placeholder. Replace it before apply. It can be the same app that runs Terraform.
- In each lane file, replace `dev_environment_owner_object_id` (`00000000-0000-0000-0000-000000000000`) with an Entra user object id from your tenant. A Developer environment needs that owner.
- Set `location` to a geography your tenant accepts (the example uses `europe`), or set `location = null` and set `macro_region` (for example `eu-efta`). Set exactly one.
- Local groups state: paste the groups output into `group_ids`.
- Remote groups state: set `backend_resource_group_name`, `backend_storage_account_name`, and `backend_container_name`, and leave `group_ids` unset. Init this stack with the same storage account so it can read `groups.tfstate`. The shared state also needs those three values so it can read each `lanes/<slug>.tfstate`.
- `cost_centre` selects the state. `cc-0000` matches the example lanes. `shared` is the fan-in and data-policy state. There is no default, so a forgotten value cannot apply the wrong blob.

`cost_centre` and the backend key have to name the same slug. `prevent_destroy` on the environments makes a mismatch fail the plan instead of deleting them.

```bash
terraform init -input=false -reconfigure -backend-config=backend.hcl -backend-config=key=lanes/cc-0000.tfstate
terraform plan
```

The `cc-0000` plan adds, per example lane:

- a Developer environment with Dataverse, in that tier's group (the example lanes set `dev_environment_type: Developer`; omit that key for Sandbox)
- an application user
- a System Administrator security role assignment, unless the pipeline application is the identity running Terraform (see below)

The example lanes are Developer, so this plan does not create a lane Entra security group. A Sandbox dev lane does. `member_object_ids` is empty in the examples. Those ids are unused while the lane is Developer, and they become group members after a switch to Sandbox. The owner email is recorded on the environment description. It is not looked up in Entra.

Data policies are not in this state. Apply `cc-0000` first, then init the shared key and apply that. The shared plan creates one data policy per tier that has a lane (medium for customer-service, large for field-operations) and lists the environment ids from `lanes/cc-0000.tfstate`.

```bash
terraform apply
```

```bash
# same terraform.tfvars, with cost_centre = "shared"
terraform init -input=false -reconfigure -backend-config=backend.hcl -backend-config=key=lanes/shared.tfstate
terraform plan
terraform apply
```

`create_release_stages` defaults to false. Set it to true only after you have read the plan that adds test and production. Dedicated test and production stay in the cost centre state. Fan-in test and production (`shared-all-lanes-test`, `shared-all-lanes-prod`) are created by the shared state.

Environment create timeouts are 90 minutes. The first apply is also the test of two things this repository cannot prove offline: service principal calls to `powerplatform_environment`, and creating the environment already inside a group via `environment_group_id`. Watch that apply.

If the shared data policy plan fails because an environment id is still unknown, apply the cost centre state first, then plan shared again.

## Move an existing lanes state

Do this once when the storage account already has `lanes.tfstate` from the unsplit stack. Do it before the first apply that uses `lanes/<slug>.tfstate`. CI refuses to plan or apply a new key while `lanes.tfstate` exists and the target blob does not, so an empty state cannot create a second copy of the environments.

The script needs an Azure login with **Storage Blob Data Contributor** on the state account, Terraform, and Python 3 with PyYAML. It does not need a Power Platform token, and it does not refresh, plan, or apply.

```bash
az login
cd stacks/lanes
# backend.hcl points at the state account.
# For a user sign-in: use_oidc = false and use_azuread_auth = true.
../../scripts/split-lanes-state.sh --dry-run
../../scripts/split-lanes-state.sh
```

What it does:

1. Pulls `lanes.tfstate` and uploads a copy to `lanes.tfstate.pre-split`. That copy is the rollback.
2. Writes dev and dedicated resources for each cost centre into `lanes/<slug>.tfstate`. Both example lanes are `CC-0000`, so they land in `lanes/cc-0000.tfstate`.
3. Writes fan-in modules and tier data policies into `lanes/shared.tfstate`.
4. Copies the tier markers and the auth marker into every new state, so the next plan does not recreate them.
5. Drops the tenant-wide environment catalogue data source. That data source is not an environment.
6. Deletes the old `lanes.tfstate` blob after the new blobs are uploaded.

`--dry-run` still reads the blob. It does not upload or delete. `--self-test` splits a fixture on the laptop and does not talk to Azure. The script stops if it finds a resource address it does not recognise, and it refuses an empty source state.

Then plan `lanes/cc-0000.tfstate` and `lanes/shared.tfstate` before you apply either. Environments must not be created or destroyed by the move itself. Apply the cost centre state first, then the shared state.

Trade-offs of the split:

- Each cost centre plan is smaller, and its state lock is its own. Cost centre applies run in parallel. Shared runs after them.
- A mistake in one cost centre cannot refresh another cost centre's environments. `prevent_destroy` still stops a wrong `cost_centre` value from deleting environments.
- The shared state reads the other blobs to build data policy membership. A new cost centre is absent from that list until its blob exists. CI checks the container and passes only the blobs that are already there, so the shared plan stays green on the pull request that adds the lane. The following apply creates the environment, then updates the policy.
- Routed personal developer environments are still outside these states, so they are not added to a data policy. See [Steering makers away from the default environment](#steering-makers-away-from-the-default-environment).

## GitHub Actions

Workflows:

| Workflow | When | What |
| --- | --- | --- |
| `plan.yml` | Every pull request, and `workflow_dispatch` | Format, validate, and lane checks. When Azure variables are set, `terraform plan` for tenant, groups, and the lanes states affected by the diff. A lane file plans that cost centre and the shared state. A change under `modules/`, `stacks/`, `tiers/`, or `.github/` plans every lanes state. `workflow_dispatch` plans every state. |
| `apply.yml` | Push to `main` that touches modules, stacks, tiers, lanes, tenant, or the workflow itself, and `workflow_dispatch` | When Azure variables are set, one approval, then apply tenant, then groups, then the same lanes matrix. Cost centre applies run in parallel. The shared lanes state runs after them. |
| `drift.yml` | 02:00 UTC, and `workflow_dispatch` | When Azure variables are set, `terraform plan -detailed-exitcode` for tenant, groups, every cost centre, and the shared lanes state. Exit code 2 opens or updates an issue titled `Drift in stacks/<label>`. Exit code 0 closes that issue when the plan is clean again. Any other exit code fails the job. |

Plan comments are marked `<!-- pp-governance-plan:LABEL -->` and truncated at 60,000 characters. `LABEL` is `tenant`, `groups`, `lanes-<cost centre>`, or `lanes-shared`. A pull request that does not touch lanes leaves the previous lanes comments in place.

Composite actions cannot read repository variables. The workflows pass `vars.*` into `.github/actions/terraform` and `.github/actions/require-azure` as inputs.

Until the required variables below are set, each workflow's Azure configuration job stays green and writes a job summary that lists what is missing. The tenant, groups, and lanes jobs are skipped, so the check is not red. Format and validate still run on every pull request. A federated credential is not tested until those variables exist. After they do, a missing credential fails the Azure login step. Setting both geography variables, or neither of them, also skips the Azure jobs with the same notice.

### Federated credentials

On the app registration, add three federated credentials. Issuer `https://token.actions.githubusercontent.com`. Audience `api://AzureADTokenExchange`.

| Use | Subject |
| --- | --- |
| Plan on a pull request | `repo:ORG/REPO:pull_request` |
| Apply and nightly drift | `repo:ORG/REPO:ref:refs/heads/main` |

Create a GitHub environment named `production` and add required reviewers. `apply.yml` selects that environment on a single `approve` job, then runs tenant, groups, and lanes. Those apply jobs do not select the environment, so their OIDC subject is `repo:ORG/REPO:ref:refs/heads/main`. In the dev tenant that credential is `gh-main-immutable`, the same one drift already uses. The `environment:production` subject is unused by these workflows. The `approve` job does not request `id-token: write`.

Pull requests from forks skip the plan job. A fork cannot mint an OIDC token for this repository.

### Variables

Repository **variables**, not secrets. The workflows never read a client secret.

| Variable | Required | Purpose |
| --- | --- | --- |
| `AZURE_CLIENT_ID` | yes | Application (client) id. |
| `AZURE_TENANT_ID` | yes | Entra tenant id. |
| `AZURE_SUBSCRIPTION_ID` | yes | Subscription that holds the state account. |
| `TF_STATE_RESOURCE_GROUP` | yes | State resource group. |
| `TF_STATE_STORAGE_ACCOUNT` | yes | State storage account. |
| `TF_STATE_CONTAINER` | yes | State container. |
| `POWER_PLATFORM_LOCATION` | one of these two | Geography, for example `europe`. The Azure jobs skip until exactly one of these is set. |
| `POWER_PLATFORM_MACRO_REGION` | one of these two | For example `eu-efta`. |
| `PIPELINE_APPLICATION_ID` | no | Client id added as an application user. Defaults to `AZURE_CLIENT_ID`. |
| `NAME_PREFIX` | no | Defaults to `ppgov`. |
| `POWER_PLATFORM_CURRENCY` | no | Defaults to `GBP`. The currency must be enabled in the tenant. |
| `CREATE_RELEASE_STAGES` | no | `true` or `false`. Defaults to false. |
| `MANAGE_DEFAULT_ENVIRONMENT_DLP` | no | `true` creates the default-environment data policy. Defaults to false. |
| `ENVIRONMENT_ROUTING_TARGET_GROUP_ID` | no | Explicit sandbox group id. When set, default-environment routing is turned on and this id is used. |
| `ROUTE_NEW_MAKERS_TO_SANDBOX` | no | `true` or `false`. Defaults to false. When true, and the explicit group id is empty, the tenant stack reads the sandbox group id from groups state. |

Language is 1033 in the example tfvars. Change `language_code` there for a local apply. The workflows pass currency and location. They leave language at the variable default.

## Add a lane

1. Copy `lanes/customer-service.yaml` to a new file. A subfolder is fine, for example `lanes/finance/payroll.yaml`. Keep every key, including nulls and empty lists. The `lane` value is the Terraform key, not the path, and it must be unique across every file under `lanes/`.
2. Set `tier` to `sandbox`, `small`, `medium`, `large`, or `exception`.
3. An `exception` lane must set `exception_expires_on` to a future `YYYY-MM-DD`. Any other tier must leave it null.
4. Put Entra object ids in `member_object_ids` for the people who should use a Sandbox or Production environment. A Developer lane has no lane group, so those ids are unused until the lane is switched to Sandbox.
5. Open a pull request. `scripts/check-lanes.py` runs in CI. The plan comment for that cost centre shows the new dev environment, and the shared plan shows the data policy once the cost centre state exists.

`lanes/operations/field-operations.yaml` shows a lane in a folder. Its key is still `field-operations`. `lanes/customer-service.yaml` stays at the top of `lanes/`. Moving a file does not replace the environment.

Two optional keys choose the dev environment type:

- `dev_environment_type`: `Sandbox` (the default when the key is missing or null) or `Developer`.
- `dev_environment_owner_object_id`: the Entra **user** object id that owns a Developer environment. Required for `Developer`, and must be null or absent for `Sandbox`.

Test and production environments are always Sandbox and Production. These keys only change the dev stage.

`outside_group: true` is supported only when the tier file has an `ungrouped_managed_environment` block. Only `tiers/exception.yaml` has one. Grouped lanes must not use `powerplatform_managed_environment`. See the limitations below.

Advisory warnings, which do not fail the check:

- `triggers.access: true` on sandbox or small
- `triggers.complexity: true` on anything other than large or exception

## Developer dev environments

The example lanes use `dev_environment_type: Developer` because the dev tenant this repository was first applied to has no paid Dataverse database capacity. A Sandbox environment with Dataverse needs at least 1 GB free, and the create fails with HTTP 409 `InsufficientCapacity_StorageDriven`. A Developer environment does not draw on tenant database capacity.

What Developer changes:

- The provider (4.2.1, preview for this type) requires `owner_id`, a user object id. The environment is that user's developer environment and counts against the per-user developer environment limit. The owner needs a licence that allows developer environments, such as the Power Apps Developer Plan.
- The environment still gets Dataverse, the tier's environment group, the pipeline application user, the security role, and the tier data policy.
- The provider rejects `dataverse.security_group_id` together with `owner_id`, so it cannot restrict a Developer environment to an Entra security group. Developer lanes get no lane group. Switching a lane to Sandbox creates one. Access is limited by the developer environment model instead: only the owner, admins, and users the owner shares with get in.
- The example lanes set `dev_environment_owner_object_id` to `00000000-0000-0000-0000-000000000000`. Replace that placeholder with a user object id from your own tenant before the first apply. After the environment exists, Terraform ignores `owner_id`, so a later edit or this public placeholder does not replace it. Transfer ownership in the Power Platform admin centre instead.

To switch back to Sandbox once the tenant has capacity, delete `dev_environment_type` and `dev_environment_owner_object_id` from the lane file (or set `dev_environment_type: Sandbox` and remove the owner). The environment type forces replacement, and `prevent_destroy` stops that plan. Remove the `lifecycle` block in `modules/lane/main.tf`, read the plan that replaces the dev environment, apply it, and then restore the block. Anything built in the old dev environment is lost unless it is in a solution.

## Steering makers away from the default environment

Default-environment routing sends a maker who opens Copilot Studio, Power Apps, or Power Automate into a personal developer environment instead of the shared default environment. This example aims those new environments at the Sandbox environment group. The Sandbox group rules then apply immediately. The environments are managed. They are not Terraform resources.

Routing stays off in a fresh clone. The tenant stack is applied before the groups stack, so the Sandbox group does not exist on the first tenant apply. Turn routing on with a second tenant apply, after groups has been applied.

Two ways to name the group. Neither puts a real id in git.

- Set `route_new_makers_to_sandbox = true` in `stacks/tenant/terraform.tfvars`, and set `backend_resource_group_name`, `backend_storage_account_name`, and `backend_container_name` to the same values as `backend.hcl`. The stack reads `environment_group_ids["sandbox"]` from `groups.tfstate`. In GitHub, set the repository variable `ROUTE_NEW_MAKERS_TO_SANDBOX` to `true`. The workflows already pass the state account variables. Leave this false until groups exists.
- Or set `environment_routing_target_group_id` to the sandbox group id printed by `terraform -chdir=stacks/groups output environment_group_ids`. In GitHub that value is `ENVIRONMENT_ROUTING_TARGET_GROUP_ID`. An explicit id is used instead of the remote state read.

`environment_routing_all_makers` stays false, so only new makers are routed. Set it to true to include makers who already build. Leave `environment_routing_target_security_group_id` unset to keep the tenant's current audience. Provider 4.2.1 treats `00000000-0000-0000-0000-000000000000` as every user.

What a maker sees: the next visit to Copilot Studio, Power Apps, or Power Automate lands in a developer environment they already own, or in a new one created in the Sandbox group. They are an admin of a new environment. If creation fails, they land in the default environment. They can still open other environments afterwards.

The Sandbox data policy is block-by-default. It allows Dataverse, Approvals, Office 365 Users, and SharePoint, and it blocks custom connectors. Sharing in the group is limited to five people and excludes security groups. Solution checker is set to block. Bing search and moving data across regions stay off, so a Copilot that needs those features will not work until you change `tiers/sandbox.yaml`. Provider 4.2.1 attaches a data policy to a list of environment ids, not to a group. This stack builds that list from the environments it manages. It does not call `powerplatform_environments`, because that data source reads Dataverse for every environment in the tenant, including Default, and the pipeline service principal is not a member of the Default environment. A routed personal developer environment is not a Terraform resource, so it is not added to the sandbox data policy. It inherits tenant-level data policies. Group rules still apply at once, because they live on the group.

Limits to plan for:

- Each person can own only so many developer environments, and they need a licence that allows one. Creating or previewing in the managed environment does not need a premium licence. Running an app or flow there does. These environments do not draw on tenant Dataverse capacity.
- Routed environments are outside this state. Destroy does not delete them.
- Only new makers are routed unless `environment_routing_all_makers` is true.
- While routing is on, this example sets `disable_developer_environment_creation_by_non_admin_users` to false. Provider 4.2.1 lists the routing attributes and does not validate that pairing. Current Microsoft documentation says the developer-environment assignment setting does not affect routing. The example still clears the block.
- Provider 4.2.1 has one target group, one audience, and the new-makers flag. It cannot express the admin centre's newer multi-rule routing, and it cannot limit routing to Copilot Studio alone.

## Tear down

Environments set `prevent_destroy = true` as a literal in `modules/lane/main.tf`. Changing `location` or `macro_region` forces replacement, and this stops a typo from planning that replacement.

To destroy environments:

1. Delete the `lifecycle { prevent_destroy = true ... }` block in `modules/lane/main.tf`. Keep the preconditions if you still want them.
2. Review `terraform plan` for `lanes/shared.tfstate`, then for each `lanes/<slug>.tfstate`.
3. `terraform destroy` the shared state first (data policies and fan-in environments), then each cost centre state. That removes environments, data policies created by this stack, application users, role assignments, and the Entra groups. Destroying an application user deletes it, including one this stack adopted because it already existed. To drop an application user from state without deleting it, `terraform state rm` that address before destroy.
4. `terraform destroy` in `stacks/groups`. That removes groups and rule sets.
5. `terraform destroy` in `stacks/tenant`. That restores the tenant settings captured at create, and deletes the default-environment data policy and the isolation policy if this stack created them. It does not delete the tenant.

Destroy the lanes states before the groups stack. A grouped environment can block group deletion.

`scripts/bootstrap-state.sh` does not delete the storage account.

## What each tier asks for

These are starting values for a dev tenant, not a recommendation for a production tenant.

| Tier | Share limit | Solution checker | Backup days | Release | Custom connectors |
| --- | --- | --- | --- | --- | --- |
| sandbox | 5 | block | 7 | dev only | Blocked |
| small | 25 | warn | 7 | fan-in test and prod | NonBusiness |
| medium | 50 | block | 14 | fan-in test and prod | NonBusiness |
| large | 10 | block | 28 | dedicated test and prod | Blocked |
| exception | 5 | block | 28 | dedicated test and prod | Blocked |

Large and exception also set an advanced connector allow-list on the group. Data policies use the full connector id (`/providers/Microsoft.PowerApps/apis/shared_commondataservice`). Advanced connector rules use the short id (`shared_commondataservice`). The provider adds the prefix.

Data policies are cumulative. A connector blocked by any policy that covers an environment stays blocked.

Sandbox, large, and exception are marked `firm: true`. Exception expiry is firm: the script and the Terraform precondition both refuse a missing or past date. Access and complexity mismatches are warnings.

`.github/CODEOWNERS` documents who should review a change (platform, the business owner, and security for large, exception, tiers, and tenant). The lines are commented out so this example does not assign owners that do not exist. Uncomment and replace them when the repository has real teams.

## Known limitations

Checked against provider **4.2.1**. Where the provider has no resource, this repository does not invent one.

- `powerplatform_managed_environment` does not apply settings while an environment is in a group. Plan returns a warning. The group rule set is the source of truth for grouped environments. This repository creates that resource only when a lane sets `outside_group: true`. Both example lanes stay in a group, so the resource is present in the module and the count stays 0.
- A setting with no group rule stays at environment level. This repository does not push those settings onto a grouped environment.
- There is no resource for Power Platform Pipelines.
- There is no resource for prepaid Copilot credit allocation. `powerplatform_billing_policy` is pay-as-you-go Azure billing. It is not wired up.
- Environment type `Developer` is preview and needs an `owner_id`. The example lanes use it for dev only (see above). Personal developer environments created by routing are a separate path, described under [Steering makers away from the default environment](#steering-makers-away-from-the-default-environment).
- `powerplatform_rbac_role_assignment` is preview. It is not wired up. Its `principal_id` would be the enterprise application object id, which is different from the client id used by `powerplatform_application_user`.
- Copilot Studio Application Insights integration is preview. It is not used.
- Agent 365 is out of scope.
- `powerplatform_environment_settings` (audit, IP firewall, and similar) is not wired up. It is easy to lock a tenant with it.
- The provider markdown for `powerplatform_environment` still says service principal authentication is not supported. The 4.2.1 resource code has no runtime check behind that sentence. The first real apply is the confirmation. The service principal limitation on `powerplatform_environment_group_rule_set` was removed in 4.2.0.
- Creating an environment with `environment_group_id` already set is the path this example uses, and it was untested against a live tenant when the files were written. Confirm the environment lands in the group and is managed.
- Provider docs say `share_max_limit` must be `-1` when share mode is `no limit`. The 4.2.1 validator requires null instead. This repository sends null. Docs also say solution checker mode `warm`. The validator accepts `warn`.
- Do not set `environment_group_id` to the empty guid. Provider 4.2.1 treated that as group membership, after which managed-environment settings could not apply. Null omits the attribute.
- An empty `member_object_ids` list means nobody is in a Sandbox or Production lane security group. A Developer lane has no lane group, and `dev_security_group_ids` is null for that lane. If Dataverse refuses the pipeline caller, set `pipeline_security_group_object_id` to the enterprise application **object** id so it is added as a member of each Sandbox or Production lane group.
- Adoption of an existing application user is ownership. Destroy deletes that user.
- Dataverse grants System Administrator to the identity that creates an environment. When `pipeline_application_id` is also the identity running Terraform (the usual CI setup), the application user already holds that role, and provider 4.2.1 refuses to create the assignment again ("This security role is already assigned to the principal"). With `manage_pipeline_security_role = null` (the default) the lanes stack detects that case and does not declare the assignment, so it is not in state and destroy does not remove it. Set the variable to `true` or `false` to override. With a CLI sign-in as a person, the assignment is created as before.
- Tenant settings destroy restores the snapshot from create. Deprecated settings (`disable_survey_feedback`, `disable_nps_comments_reachout`, `disable_create_from_image`, `disable_create_from_figma`, `enable_open_ai_bot_publishing`) are left unset on purpose.
- The default-environment data policy stays off until `manage_default_environment_dlp` is true. It is `OnlyEnvironments` on the environment whose type is `Default`.
- `powerplatform_tenant_isolation_policy` is a real resource, and it is not in the tenant stack. Provider 4.2.1 fails `terraform validate` when `allowed_tenants` is unknown, which is what a variable or a `count` of zero produces during validate. `examples/tenant-isolation` keeps `is_disabled = true` and an empty allow list as literals. Edit those arguments and apply that root on its own when you intend to manage cross-tenant isolation. Read the plan first. The GitHub workflows do not apply it.

## Security and limitations

This repo is a learning example that goes with a blog post. It has been applied to a real dev tenant, but it isn't hardened for production, so review the points below before adapting it.

1. **One highly privileged identity.** The single app registration is a Power Platform Administrator and also has Microsoft Graph permission to create groups. Anyone who can get a token for it can change governance across the whole tenant. Split the work: a narrow identity for group creation, a separate identity for Power Platform changes, and the smallest role that can still do each job.
2. **Pull request plans run as that admin identity.** The `pull_request` federated credential lets any branch in this repository, once it has an open pull request, obtain an admin token during plan. Providers and external data sources can run code during a plan. Use a separate read-only identity for plan, and keep the admin credential on the `production` GitHub environment only.
3. **One approval, then the main-branch credential.** `apply.yml` asks for the `production` environment once, on the `approve` job. Tenant, groups, and every lanes state wait for that job. Apply jobs authenticate as `repo:ORG/REPO:ref:refs/heads/main`. Add required reviewers on `production`, and limit that environment to `main`. This repository does not configure those rules. Without them the environment name is only a label, and a push to `main` applies as soon as the workflow starts.
4. **Protect `main`.** Require a pull request review and the passing checks, and block force pushes. A push to `main` runs apply, so it has the same reach as the tenant admin identity.
5. **State storage.** Terraform state can hold environment ids, Dataverse URLs, and group object ids. `scripts/bootstrap-state.sh` now disables shared key access and enables blob versioning and soft delete (14 days for blobs and containers). It also sets TLS 1.2, HTTPS only, and no public blob access, then grants **Storage Blob Data Contributor** on the whole account to the pipeline service principal and, when set, one user. The backend examples and CI set `use_azuread_auth = true` so Terraform uses Entra ID. The role is still read and write on the whole account. Narrow it to named admins if more people should not read state.
6. **Avoid long-lived client secrets.** The workflows use OIDC and this repo commits no client secret. For a local run, prefer `az login` (`use_cli = true`). If you create a client secret to get unstuck, delete it when the run is done.
7. **Supply chain.** GitHub Actions are pinned to tags, not commit SHAs: `actions/checkout@v4`, `hashicorp/setup-terraform@v3`, `azure/login@v2`, `actions/github-script@v7`, and `actions/upload-artifact@v4`. Pin those actions to SHAs before you trust the workflows with a real tenant. Terraform lock files are already committed for `stacks/tenant`, `stacks/groups`, `stacks/lanes`, `examples/register-admin-application`, and `examples/tenant-isolation`.
8. **Keep drift plan-only and read-only.** `drift.yml` runs `terraform plan -detailed-exitcode` and opens or closes an issue. It does not apply. It still authenticates as the same admin app, with the `ref:refs/heads/main` credential. Leave the workflow on plan, and move it to a read-only identity.
9. **Scope.** The example lanes use Developer environments because the test tenant had no paid Dataverse capacity. Those public lane files keep the placeholder owner id. Terraform ignores `owner_id` after create, so that placeholder does not plan a replacement, and you transfer ownership in the admin centre instead. The DLP tiers and environment group rules are illustrative, not a recommended baseline. This is not a replacement for Microsoft admin tooling or Agent 365. Provider gaps are listed under [Known limitations](#known-limitations).

## Formatting

```bash
terraform fmt -recursive
terraform fmt -check -recursive
./scripts/validate-all.sh
```

`validate-all.sh` installs PyYAML if it is missing, runs the lane, state-split, and repository self-tests, checks formatting, and runs `terraform init -backend=false` and `terraform validate` in each stack and in `examples/register-admin-application`.

`.pre-commit-config.yaml` runs `terraform fmt -recursive`. Commit the `.terraform.lock.hcl` files that init writes. They are not gitignored.

## Licence

MIT. See [LICENSE](LICENSE).

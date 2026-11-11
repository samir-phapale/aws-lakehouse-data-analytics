# CI/CD: GitHub -> CodePipeline -> Terraform, with OPA checks

The code lives on GitHub (`samir-phapale/aws-lakehouse-data-analytics`). The lakehouse (main
Terraform root `infrastructure/terraform`) is deployed only by this pipeline, never from a laptop.
The pipeline itself is a separate, small Terraform root (`cicd/terraform`) applied once by hand.

```
push to main on GitHub ──> lakehouse-dev-pipeline (CodePipeline V2)
                             1 Source   GitHub via connection lakehouse-dev-github, branch main
                             2 Plan     CodeBuild lakehouse-dev-validate-plan
                             3 Approve  manual approval
                             4 Apply    CodeBuild lakehouse-dev-apply
```

| Stage | What runs (buildspec) |
| --- | --- |
| Plan | `cicd/buildspecs/plan.yml`: install pinned Terraform and conftest (checksums verified), `terraform fmt -check -recursive`, `conftest verify` (policy unit tests), `pytest tests/unit`, validate the cicd root, `terraform init` of the main root with `-backend-config` flags, `validate`, `plan -out=tfplan`, `show -json` -> `plan.json`, `conftest test plan.json -p opa/policies`. Any failure stops the pipeline. Output artifact: the source plus `tfplan`, `plan.json` and `.terraform.lock.hcl` |
| Approve | A person reads the plan in the Plan build log (CodeBuild -> lakehouse-dev-validate-plan -> latest build) and approves or rejects in the console, or `aws codepipeline put-approval-result` |
| Apply | `cicd/buildspecs/apply.yml`: same Terraform, `init -lockfile=readonly`, `terraform apply tfplan` - exactly the reviewed plan. If the state changed after the plan, Terraform refuses the stale plan; release a new pipeline run |

## OPA policies (`opa/policies`, tests in `opa/tests`)

Evaluated with conftest against `terraform show -json` output. Only managed resources being
created or updated are checked (deletes and no-ops are skipped; a replacement counts as a create).

| Rule | Resource |
| --- | --- |
| `sse_algorithm` is `aws:kms` | `aws_s3_bucket_server_side_encryption_configuration` |
| All four public access block flags true | `aws_s3_bucket_public_access_block` |
| No Allow statement with action `*` or `<service>:*` (resource `*` is allowed) | `aws_iam_role_policy`, `aws_iam_policy` |
| `security_configuration` set | `aws_glue_job` |
| `storage_encrypted` true, `publicly_accessible` false | `aws_db_instance` |
| `publicly_accessible` false | `aws_redshiftserverless_workgroup` |
| `enable_key_rotation` true | `aws_kms_key` |
| Tags `Project`, `Environment`, `ManagedBy` present | every resource with `tags_all` |

The IAM rule also checks policies the plan leaves unchanged. A policy document that references
resources created in the same plan is only known at apply time, so it is skipped on that first plan
and checked on every later one.

Run locally (conftest binary from the GitHub releases of open-policy-agent/conftest):

```bash
conftest verify -p opa/policies -p opa/tests
terraform -chdir=infrastructure/terraform show -json tfplan > plan.json
conftest test plan.json -p opa/policies
```

## What `cicd/terraform` creates

| Resource | Name |
| --- | --- |
| CodeConnections connection to GitHub (created pending, authorized once in the console) | `lakehouse-dev-github` |
| KMS key (module `kms`), rotation on | alias `lakehouse-dev-cicd-data` |
| Artifacts bucket (module `s3`: SSE-KMS, versioning, Block Public Access, TLS-only, allow-list) | `sam-lakehouse-pipeline-artifacts-<account>`; allows the pipeline role, the CodeBuild role and the SSO admin role (`deployer_admin_role_arn` in `terraform.tfvars`) |
| CodeBuild projects | `lakehouse-dev-validate-plan`, `lakehouse-dev-apply` (pipeline), `lakehouse-dev-destroy` (manual) (image `aws/codebuild/standard:7.0`) |
| CodeBuild log group, KMS-encrypted, 14 days | `/aws/codebuild/lakehouse-dev-cicd` |
| CodeBuild role | `lakehouse-dev-cicd-deploy` |
| CodePipeline + its role | `lakehouse-dev-pipeline`, `lakehouse-dev-cicd-pipeline` (the GitHub connection, the two projects, the artifacts bucket and key only) |

**Least-privilege exception.** The CodeBuild role has the AWS managed `AdministratorAccess`
policy. It runs `terraform apply` for the whole main root, which creates IAM roles, VPC, RDS, MSK,
Glue, Lake Formation grants and more; a scoped policy would have to be rewritten with every new
resource type. It is the one deliberate exception: only CodeBuild in this account can assume it,
and nothing is applied before the plan has passed the OPA policies and a person has approved it.
Its ARN is fixed (`arn:aws:iam::<account>:role/lakehouse-dev-cicd-deploy`) because the main root
puts it in the bucket allow-lists by name.

Terraform version: all three buildspecs pin Terraform `1.15.4`. Terraform refuses state written
by a newer version, and a plan file applies only with the version that made it. Raise
`TERRAFORM_VERSION` and `TERRAFORM_SHA256` in all three together, never lower them.

## One-time bootstrap

Prerequisites: `aws sso login --profile vr-sso`, Terraform >= 1.11, the GitHub CLI (`gh auth login`).

1. Give the project its own Git repository and push it to GitHub. The enclosing repo is the whole
   `VS_Code` folder, so the project needs its own:

   ```bash
   git init -b main          # inside aws-lakehouse-data-analytics
   git add . && git commit -m "Initial commit"
   gh repo create samir-phapale/aws-lakehouse-data-analytics --public --source . --push
   ```

   Gitignored files (`backend.hcl`, `tfplan`, state) never reach the repo; the pipeline passes
   the backend settings as `-backend-config` flags from project environment variables.

2. Apply the pipeline root:

   ```bash
   export AWS_PROFILE=vr-sso
   cp cicd/terraform/backend.hcl.example cicd/terraform/backend.hcl   # set the state bucket
   terraform -chdir=cicd/terraform init -backend-config=backend.hcl
   terraform -chdir=cicd/terraform apply          # reads cicd/terraform/terraform.tfvars
   ```

   A new V2 pipeline starts one run straight away; it fails at Source until step 3 is done.

3. Authorize the GitHub connection (created `PENDING`): console -> Developer Tools -> Settings ->
   Connections -> `lakehouse-dev-github` -> Update pending connection -> install or choose the
   AWS Connector for GitHub app with access to the repository.

4. Make the CodeBuild role a Lake Formation data lake admin (the main root creates Lake Formation
   grants, and only data lake admins may grant). The script keeps every existing admin and setting
   and does nothing if the role is already an admin:

   ```bash
   scripts/add_lake_formation_admin.sh "$(terraform -chdir=cicd/terraform output -raw codebuild_role_arn)"
   ```

5. Keep the human admin in the lake buckets. When the pipeline applies the main root, the
   "role running terraform" it adds to every bucket allow-list is the CodeBuild role, so the SSO
   admin role must stay listed in `admin_principal_arns` in
   `infrastructure/terraform/environments/dev/terraform.tfvars` (it is), or the next pipeline
   apply removes it from the bucket policies and Lake Formation grants.

6. Start the first run: CodePipeline -> `lakehouse-dev-pipeline` -> Release change (or push a
   commit). Read the plan in the Plan build log, approve (Approve -> Review), and the Apply stage
   runs. A fresh deploy is 239 resources.

After the bootstrap, every change to the main root goes through the same path: commit, push to
`main`, approve. The stack stays up until the work is finished.

## Destroy (once, when the work is finished)

Not a pipeline stage. The CodeBuild project `lakehouse-dev-destroy` checks out `main` and runs
`terraform destroy` on the main root (`cicd/buildspecs/destroy.yml`). It refuses to run unless the
build overrides `CONFIRM_DESTROY` with the environment name:

```bash
aws codebuild start-build --project-name lakehouse-dev-destroy \
  --environment-variables-override name=CONFIRM_DESTROY,value=lakehouse-dev,type=PLAINTEXT
```

Destroy the pipeline root itself (`terraform -chdir=cicd/terraform destroy`) only after that,
since its CodeBuild role is what runs the main root's destroy.

## Layout

- `cicd/terraform/` - the pipeline root (backend key `lakehouse/cicd/terraform.tfstate`); reuses
  `infrastructure/terraform/modules/kms` and `modules/s3`
- `cicd/buildspecs/` - `plan.yml`, `apply.yml` (pipeline stages), `destroy.yml` (manual project)
- `cicd/codebuild/`, `cicd/codepipeline/` - still empty: the pipeline is small enough to live in
  one root
- `opa/policies/`, `opa/tests/` - conftest policies and their unit tests

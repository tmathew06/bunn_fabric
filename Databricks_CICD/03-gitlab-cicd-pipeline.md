# Doc 3: GitLab CI/CD Pipeline — Automating Your Deployments

## What This Doc Covers

How to write `.gitlab-ci.yml` from scratch, set up authentication between GitLab and Databricks, and build a pipeline that validates and deploys your DAB bundle automatically.

---

## The Mental Model

GitLab CI/CD is an **automation engine** built into GitLab. Every time you push code (or merge an MR), GitLab reads `.gitlab-ci.yml` and executes the steps you defined. Those steps run on **runners** — temporary Linux containers that GitLab manages for you.

Think of it this way: `.gitlab-ci.yml` is a script that a robot runs every time you push code. The robot starts from a clean Linux machine, installs what it needs, runs your commands, and reports back success or failure.

---

## Anatomy of `.gitlab-ci.yml`

Here's the full structure, then we'll break it down:

```yaml
# ─── Global Settings ─────────────────────────────────────
image: python:3.11-slim                   # Base Docker image for all jobs

variables:
  DATABRICKS_HOST: ${DATABRICKS_HOST}     # From GitLab CI/CD Variables
  DATABRICKS_TOKEN: ${DATABRICKS_TOKEN}   # From GitLab CI/CD Variables
  BUNDLE_TARGET: "dev"

# ─── Stages (run in order) ───────────────────────────────
stages:
  - validate
  - deploy

# ─── Setup (reusable script block) ──────────────────────
.setup_databricks_cli: &setup_cli
  before_script:
    - pip install databricks-cli --quiet
    - curl -fsSL https://raw.githubusercontent.com/databricks/setup-cli/main/install.sh | sh
    - databricks --version

# ─── Stage 1: Validate ──────────────────────────────────
validate_bundle:
  stage: validate
  <<: *setup_cli
  script:
    - databricks bundle validate -t ${BUNDLE_TARGET}
  rules:
    - if: '$CI_PIPELINE_SOURCE == "merge_request_event"'
    - if: '$CI_COMMIT_BRANCH == "main"'

# ─── Stage 2: Deploy ────────────────────────────────────
deploy_bundle:
  stage: deploy
  <<: *setup_cli
  script:
    - databricks bundle deploy -t ${BUNDLE_TARGET}
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
  environment:
    name: dev
```

Now let's walk through every piece.

---

## Section-by-Section Walkthrough

### `image:` — The Runner Environment

```yaml
image: python:3.11-slim
```

This tells GitLab which Docker image to use as the base for your runner. The runner is the temporary machine that executes your pipeline. `python:3.11-slim` gives you a minimal Linux environment with Python pre-installed — which you need for the Databricks CLI.

**Why `python:3.11-slim`?** The Databricks CLI is distributed as a standalone binary, but having Python available is useful for any pre/post-processing scripts. The `-slim` variant keeps the image small, which means faster pipeline starts.

---

### `variables:` — Pipeline-Level Variables

```yaml
variables:
  DATABRICKS_HOST: ${DATABRICKS_HOST}
  DATABRICKS_TOKEN: ${DATABRICKS_TOKEN}
  BUNDLE_TARGET: "dev"
```

These are environment variables available to every job in the pipeline. Note the difference between two types:

**GitLab CI/CD Variables (secrets):** `DATABRICKS_HOST` and `DATABRICKS_TOKEN` reference values stored securely in GitLab (we'll set these up in the bootstrapping guide). They are *not* stored in your YAML file — that would expose credentials in your repo.

**Inline variables:** `BUNDLE_TARGET` is defined right here with a default value. You can override it for different branches or manual runs.

The Databricks CLI automatically reads `DATABRICKS_HOST` and `DATABRICKS_TOKEN` from environment variables for authentication. No explicit login command needed — just having these set is enough.

---

### `stages:` — Execution Order

```yaml
stages:
  - validate
  - deploy
```

Stages define the sequence. GitLab runs all jobs in `validate` first. If they all pass, it moves to `deploy`. If any job in a stage fails, the pipeline stops — later stages don't run.

For your dev-only setup, two stages is perfect. When you add environments later, you might expand to:

```yaml
stages:
  - validate
  - deploy_dev
  - test
  - deploy_staging
  - deploy_prod
```

---

### YAML Anchors — Reusable Script Blocks

```yaml
.setup_databricks_cli: &setup_cli
  before_script:
    - pip install databricks-cli --quiet
    - curl -fsSL https://raw.githubusercontent.com/databricks/setup-cli/main/install.sh | sh
    - databricks --version
```

This is a YAML feature (not GitLab-specific) called an **anchor**. The `&setup_cli` creates a reusable block, and `<<: *setup_cli` merges it into a job. This avoids repeating the CLI installation steps in every job.

**What the script does:**

1. `pip install databricks-cli` — Installs the legacy Python-based CLI (sometimes needed for compatibility).
2. `curl ... | sh` — Installs the modern Databricks CLI (the Go-based one that supports `bundle` commands).
3. `databricks --version` — Verifies the installation worked. If this fails, you'll see it in the pipeline logs.

The leading dot in `.setup_databricks_cli` tells GitLab this is a **hidden job** — it won't run as its own pipeline step. It exists only to be referenced by other jobs.

---

### Job: `validate_bundle`

```yaml
validate_bundle:
  stage: validate
  <<: *setup_cli
  script:
    - databricks bundle validate -t ${BUNDLE_TARGET}
  rules:
    - if: '$CI_PIPELINE_SOURCE == "merge_request_event"'
    - if: '$CI_COMMIT_BRANCH == "main"'
```

**What this job does:**

1. Runs in the `validate` stage (first).
2. Installs the Databricks CLI (via the anchor).
3. Runs `databricks bundle validate` — this checks your `databricks.yml` for syntax errors, invalid references, and schema violations. It does NOT deploy anything.

**When it runs (the `rules` section):**

- On merge request events — so you get validation feedback before merging.
- On pushes to `main` — as a safety check before deployment.

This means every MR gets automatic validation. If your YAML is broken, the MR shows a red X and your team knows not to merge.

---

### Job: `deploy_bundle`

```yaml
deploy_bundle:
  stage: deploy
  <<: *setup_cli
  script:
    - databricks bundle deploy -t ${BUNDLE_TARGET}
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
  environment:
    name: dev
```

**What this job does:**

1. Runs in the `deploy` stage (second, only if validation passed).
2. Installs the Databricks CLI.
3. Runs `databricks bundle deploy` — this pushes your notebooks and creates/updates jobs in Databricks.

**When it runs:**

- Only on pushes to `main`. Merge requests do NOT trigger deployment.

This is the key workflow: MRs validate, `main` deploys. Your team reviews code in an MR, sees that validation passes, merges, and deployment happens automatically.

**The `environment` block:**

```yaml
environment:
  name: dev
```

This tags the deployment in GitLab's UI so you can see deployment history under **Deployments > Environments**. It's purely informational but very useful for tracking what's deployed where.

---

## The `rules:` System — When Things Run

`rules` is the most important concept for controlling your pipeline. Here's a quick reference:

| Rule | Meaning |
|---|---|
| `if: '$CI_COMMIT_BRANCH == "main"'` | Run when code is pushed to `main` |
| `if: '$CI_PIPELINE_SOURCE == "merge_request_event"'` | Run when an MR is opened or updated |
| `if: '$CI_COMMIT_TAG'` | Run when a git tag is created |
| `when: manual` | Show a "play" button; only runs when someone clicks it |
| `changes: ["src/**/*"]` | Only run if files in `src/` changed |

You can combine these. For example, a manual production deploy:

```yaml
deploy_prod:
  stage: deploy_prod
  script:
    - databricks bundle deploy -t prod
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
      when: manual
  environment:
    name: prod
```

This creates a deploy button that only appears on `main` pushes and requires someone to manually click it. Great for production safety.

---

## Authentication — Connecting GitLab to Databricks

This is the part that trips people up. GitLab runners need credentials to talk to your Databricks workspace. Here's how it works:

### Option A: Personal Access Token (Simplest — Good for Dev)

1. In Databricks, go to **User Settings > Developer > Access Tokens**.
2. Generate a token. Copy it.
3. In GitLab, go to **Settings > CI/CD > Variables**.
4. Add two variables:

| Key | Value | Options |
|---|---|---|
| `DATABRICKS_HOST` | `https://your-workspace.cloud.databricks.com` | Protected, Masked |
| `DATABRICKS_TOKEN` | `dapi...your-token...` | Protected, Masked |

**"Protected"** means the variable is only available on protected branches (like `main`). This prevents a rogue feature branch from accessing your credentials.

**"Masked"** means the value is hidden in pipeline logs. If the token accidentally gets printed, GitLab redacts it.

### Option B: Service Principal (Better — For Production Later)

When you add production, you'll want a service principal instead of a personal token. A service principal is a non-human identity in Databricks — it won't break when someone leaves the team or resets their password. We'll cover this when you're ready to add environments.

### Option C: OAuth M2M (Most Modern)

Databricks also supports OAuth machine-to-machine authentication. This uses a client ID and client secret instead of a token. It's the most modern approach and aligns with Databricks' direction, but it requires more setup. Something to consider for the future.

---

## Pipeline Flow — Visual Summary

```
Developer pushes          GitLab CI/CD                Databricks
to feature branch         Pipeline                    Workspace
     │                       │                           │
     │  push feature/xyz     │                           │
     │──────────────────────>│                           │
     │                       │  validate_bundle          │
     │                       │  (runs on MR)             │
     │  ✓ or ✗ shown on MR  │                           │
     │<──────────────────────│                           │
     │                       │                           │
     │  merge to main        │                           │
     │──────────────────────>│                           │
     │                       │  validate_bundle          │
     │                       │  ────────────────>pass    │
     │                       │                           │
     │                       │  deploy_bundle            │
     │                       │  ─────────────────────────>│
     │                       │                           │  Jobs updated
     │                       │                           │  Notebooks synced
     │  ✓ pipeline passed    │                           │
     │<──────────────────────│                           │
```

---

## Expanding Later — Multi-Environment Pipeline

When you're ready for staging and production, here's how the pipeline grows:

```yaml
stages:
  - validate
  - deploy_dev
  - test
  - deploy_prod

validate_bundle:
  stage: validate
  <<: *setup_cli
  script:
    - databricks bundle validate -t dev
  rules:
    - if: '$CI_PIPELINE_SOURCE == "merge_request_event"'
    - if: '$CI_COMMIT_BRANCH == "main"'

deploy_dev:
  stage: deploy_dev
  <<: *setup_cli
  script:
    - databricks bundle deploy -t dev
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
  environment:
    name: dev

integration_tests:
  stage: test
  <<: *setup_cli
  script:
    - databricks bundle run -t dev silver_daily_refresh
    # Add test assertions here
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'

deploy_prod:
  stage: deploy_prod
  <<: *setup_cli
  variables:
    DATABRICKS_HOST: ${PROD_DATABRICKS_HOST}
    DATABRICKS_TOKEN: ${PROD_DATABRICKS_TOKEN}
  script:
    - databricks bundle deploy -t prod
  rules:
    - if: '$CI_COMMIT_BRANCH == "main"'
      when: manual          # ← requires manual click to deploy prod
  environment:
    name: prod
```

Notice how `deploy_prod` uses different variables (`PROD_DATABRICKS_HOST`), overriding the defaults. This keeps dev and prod credentials separate.

---

## Gotchas and Tips

1. **YAML indentation in `.gitlab-ci.yml` uses 2 spaces.** Same as `databricks.yml`. Be consistent.

2. **Pipeline won't run?** Check that your `.gitlab-ci.yml` is in the repo root (not a subdirectory) and that the branch rules match your branch name.

3. **"Variable is not set" errors:** Make sure you've added `DATABRICKS_HOST` and `DATABRICKS_TOKEN` in GitLab's CI/CD Variables section. Check that they're not marked "Protected" if you're testing on an unprotected branch.

4. **Slow pipelines?** The CLI install step takes 20-30 seconds each time. You can speed this up by building a custom Docker image with the CLI pre-installed, but that's an optimization for later.

5. **Debugging failed pipelines:** Click the failed job in GitLab's pipeline view. You'll see the full terminal output. The Databricks CLI gives decent error messages — look for the first red line.

6. **Don't store credentials in `.gitlab-ci.yml`.** Always use GitLab CI/CD Variables. This is a hard rule.

7. **Merge request pipelines vs. branch pipelines:** By default, both might trigger. The `rules` configuration above prevents this — MRs get validate-only, `main` gets validate + deploy.

---

## Next Up

**Doc 4** is the hands-on bootstrapping guide — the exact commands you'll run to go from zero to a working pipeline.

---

## Sources

- [GitLab CI/CD with Databricks](https://docs.databricks.com/aws/en/dev-tools/ci-cd/)
- [Building CI Pipeline with DAB and GitLab](https://hackernoon.com/building-ci-pipeline-with-databricks-asset-bundle-and-gitlab)
- [Streamlining Databricks Deployments with DABs and GitLab CI/CD](https://www.freshgravity.com/insights-blogs/streamlining-databricks-deployments/)
- [Databricks CI/CD Best Practices](https://docs.databricks.com/aws/en/dev-tools/ci-cd/best-practices)

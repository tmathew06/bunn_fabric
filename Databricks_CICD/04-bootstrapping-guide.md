# Doc 4: Bootstrapping Guide — From Zero to Working Pipeline

## What This Doc Covers

The exact steps, in order, to go from nothing to a deployed DAB bundle with GitLab CI/CD running. Follow these like a recipe.

---

## Prerequisites Checklist

Before starting, confirm you have:

- [ ] A Databricks workspace you can access (your dev workspace)
- [ ] Admin or workspace-level permissions to create jobs and access tokens
- [ ] A GitLab account with a project (repo) created
- [ ] Git installed on your machine
- [ ] A terminal (macOS Terminal, Windows Terminal, WSL, etc.)

---

## Phase 1: Install the Databricks CLI

The Databricks CLI is the tool that makes DAB work. It's a single binary — no complex installation.

### macOS / Linux

```bash
# Install the CLI
curl -fsSL https://raw.githubusercontent.com/databricks/setup-cli/main/install.sh | sh

# Verify it works
databricks --version
```

You should see something like `Databricks CLI v0.232.0` (version may vary).

### Windows

```powershell
# Using winget (Windows Package Manager)
winget install Databricks.DatabricksCLI

# Or download directly from:
# https://github.com/databricks/cli/releases

# Verify
databricks --version
```

### Verify Installation

If `databricks --version` prints a version number, you're good. If not, make sure the install directory is on your `PATH`.

---

## Phase 2: Authenticate the CLI with Your Workspace

You need to tell the CLI how to talk to your Databricks workspace.

### Step 2a: Generate a Personal Access Token

1. Log into your Databricks workspace in a browser.
2. Click your profile icon (top-right corner).
3. Go to **Settings**.
4. In the left sidebar, click **Developer**.
5. Next to **Access tokens**, click **Manage**.
6. Click **Generate new token**.
7. Give it a description like `DAB CLI - dev` and set an expiration (90 days is reasonable).
8. **Copy the token immediately.** You won't be able to see it again.

### Step 2b: Configure the CLI

```bash
# Set up a connection profile
databricks configure --host https://your-workspace.cloud.databricks.com
```

When prompted, paste your token. This creates a config file at `~/.databrickscfg` that looks like:

```ini
[DEFAULT]
host  = https://your-workspace.cloud.databricks.com
token = dapi_your_token_here
```

### Step 2c: Test the Connection

```bash
# List your workspace contents — if this works, you're authenticated
databricks workspace ls /Users
```

You should see a list of user directories. If you get an authentication error, double-check your host URL and token.

---

## Phase 3: Scaffold Your Project

Now let's create the project structure.

### Step 3a: Create the Project Directory

```bash
# Create and enter the project directory
mkdir silver-layer-project
cd silver-layer-project

# Initialize git
git init
```

### Step 3b: Create the Directory Structure

```bash
# Create all directories
mkdir -p src/notebooks
mkdir -p resources
mkdir -p tests
```

### Step 3c: Create `databricks.yml`

Create the file `databricks.yml` in the project root with this content:

```yaml
bundle:
  name: silver-layer-transforms

include:
  - "resources/*.yml"

variables:
  catalog_name:
    description: "Unity Catalog name"
    default: "dev_catalog"
  schema_name:
    description: "Target schema for silver tables"
    default: "silver"
  cluster_id:
    description: "Cluster ID for job execution"

targets:
  dev:
    mode: development
    default: true
    workspace:
      host: https://your-workspace.cloud.databricks.com   # ← CHANGE THIS
    variables:
      catalog_name: "dev_catalog"                          # ← CHANGE THIS
      schema_name: "silver"                                # ← CHANGE THIS
      cluster_id: "YOUR_CLUSTER_ID_HERE"                   # ← CHANGE THIS
```

**Values you need to fill in:**

| Placeholder | Where to Find It |
|---|---|
| `workspace.host` | Your Databricks workspace URL (from the browser address bar) |
| `catalog_name` | The Unity Catalog name you use in dev |
| `schema_name` | The schema where your silver tables go |
| `cluster_id` | Compute > your cluster > look for the ID in the URL or the JSON view (format: `0407-123456-abcdef`) |

### Step 3d: Create a Sample Job Resource

Create `resources/job_silver_sample.yml`:

```yaml
resources:
  jobs:
    silver_sample_job:
      name: "Silver - Sample Transform"

      job_clusters:
        - job_cluster_key: "transform_cluster"
          new_cluster:
            spark_version: "14.3.x-scala2.12"
            node_type_id: "i3.xlarge"
            num_workers: 1

      tasks:
        - task_key: "transform_sample"
          job_cluster_key: "transform_cluster"
          notebook_task:
            notebook_path: "../src/notebooks/transform_sample.sql"
            base_parameters:
              catalog: ${var.catalog_name}
              schema: ${var.schema_name}
```

**Note:** If you'd rather use an existing cluster instead of a job cluster, replace the `job_clusters` block and `job_cluster_key` with:

```yaml
      tasks:
        - task_key: "transform_sample"
          existing_cluster_id: ${var.cluster_id}
          notebook_task:
            notebook_path: "../src/notebooks/transform_sample.sql"
            base_parameters:
              catalog: ${var.catalog_name}
              schema: ${var.schema_name}
```

### Step 3e: Create a Sample Notebook

Create `src/notebooks/transform_sample.sql`:

```sql
-- Databricks notebook source
-- MAGIC %md
-- MAGIC # Sample Silver Transform
-- MAGIC This notebook demonstrates the bronze-to-silver pattern.
-- MAGIC It reads a sql_variant column from bronze and shreds it into typed columns.

-- Use parameterized catalog and schema
USE CATALOG ${catalog};
USE SCHEMA ${schema};

-- Example: Shred a json column from bronze into a silver table
-- Adjust the table names and columns to match your actual data
CREATE OR REPLACE TABLE silver_sample_table AS
SELECT
  raw.id,
  raw.data:customer_name::STRING     AS customer_name,
  raw.data:order_date::DATE          AS order_date,
  raw.data:amount::DECIMAL(10,2)     AS amount,
  raw.data:status::STRING            AS status,
  current_timestamp()                AS silver_loaded_at
FROM bronze.raw_events AS raw
WHERE raw.data:event_type::STRING = 'order';
```

This is a placeholder — replace it with your actual transform logic.

---

## Phase 4: Validate Locally

Before involving GitLab at all, make sure your bundle is valid.

```bash
# From the project root
databricks bundle validate
```

**If it succeeds:** You'll see a JSON summary of your bundle resources. Move on.

**If it fails:** Read the error message carefully. Common issues at this stage include YAML indentation errors, missing variables (add defaults or provide values), and invalid `spark_version` strings (check the Databricks docs for current versions).

---

## Phase 5: Deploy Locally (Test Before CI/CD)

Let's deploy manually to verify everything works before automating it.

```bash
# Deploy to your dev workspace
databricks bundle deploy -t dev
```

**What happens:**

1. The CLI uploads your notebooks to your workspace (under `/Users/your.email/.bundle/silver-layer-transforms/dev/files/`).
2. It creates the job defined in your resource YAML.
3. It prints a summary of what was created/updated.

**Verify in the Databricks UI:**

1. Go to **Workflows** in the left sidebar.
2. Look for a job prefixed with `[dev your.email]` — that's development mode prefixing.
3. Click into it and verify the task configuration looks right.

### Optional: Run the Job

```bash
# Trigger a run
databricks bundle run -t dev silver_sample_job
```

This starts the job. You can watch it in the Databricks UI under **Workflows > your job > Runs**.

---

## Phase 6: Set Up GitLab CI/CD

Now let's automate what you just did manually.

### Step 6a: Create `.gitlab-ci.yml`

Create `.gitlab-ci.yml` in the project root:

```yaml
image: python:3.11-slim

variables:
  DATABRICKS_HOST: ${DATABRICKS_HOST}
  DATABRICKS_TOKEN: ${DATABRICKS_TOKEN}
  BUNDLE_TARGET: "dev"

stages:
  - validate
  - deploy

.setup_databricks_cli: &setup_cli
  before_script:
    - apt-get update && apt-get install -y curl --quiet
    - curl -fsSL https://raw.githubusercontent.com/databricks/setup-cli/main/install.sh | sh
    - databricks --version

validate_bundle:
  stage: validate
  <<: *setup_cli
  script:
    - databricks bundle validate -t ${BUNDLE_TARGET}
  rules:
    - if: '$CI_PIPELINE_SOURCE == "merge_request_event"'
    - if: '$CI_COMMIT_BRANCH == "main"'

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

**Note the `apt-get install -y curl` line.** The `python:3.11-slim` image might not have `curl` pre-installed, and we need it to download the Databricks CLI.

### Step 6b: Add CI/CD Variables in GitLab

1. Go to your GitLab project in the browser.
2. Navigate to **Settings > CI/CD**.
3. Expand the **Variables** section.
4. Click **Add variable** and add:

| Key | Value | Flags |
|---|---|---|
| `DATABRICKS_HOST` | `https://your-workspace.cloud.databricks.com` | **Protected**, **Masked** |
| `DATABRICKS_TOKEN` | `dapi_your_token_here` | **Protected**, **Masked** |

**Important flags:**

- **Protected** = only available on protected branches. Make sure `main` is a protected branch (it usually is by default).
- **Masked** = hidden in job logs. Prevents accidental exposure.

### Step 6c: Create `.gitignore`

Create a `.gitignore` file so you don't commit junk:

```gitignore
# Databricks CLI config (contains your token!)
.databrickscfg

# Bundle state (managed by DAB)
.bundle/

# Python
__pycache__/
*.pyc
.venv/
venv/

# IDE
.idea/
.vscode/
*.swp

# OS
.DS_Store
Thumbs.db
```

---

## Phase 7: Push and Watch the Magic

### Step 7a: Connect to GitLab

```bash
# Add your GitLab repo as the remote origin
git remote add origin https://gitlab.com/your-group/silver-layer-project.git

# Or if using SSH:
# git remote add origin git@gitlab.com:your-group/silver-layer-project.git
```

### Step 7b: Commit Everything

```bash
git add .
git status  # Review what's being committed — no secrets!
git commit -m "Initial silver layer project with DAB and GitLab CI/CD"
```

### Step 7c: Push to Main

```bash
git push -u origin main
```

### Step 7d: Watch the Pipeline

1. Go to your GitLab project in the browser.
2. Click **Build > Pipelines** in the left sidebar.
3. You should see a pipeline running with two stages: `validate` and `deploy`.
4. Click into it to watch the logs in real time.

**If it's green:** Congratulations, you have a working CI/CD pipeline.

**If it's red:** Click the failed job, read the error, and troubleshoot:

| Error | Fix |
|---|---|
| `DATABRICKS_HOST: not set` | Add the variable in GitLab CI/CD settings |
| `DATABRICKS_TOKEN: not set` | Add the variable in GitLab CI/CD settings |
| `Error: authentication required` | Token is expired or incorrect |
| `bundle validate failed` | YAML syntax error — check indentation |
| `curl: not found` | Add `apt-get install -y curl` to `before_script` |

---

## Phase 8: Establish Your Workflow

Now that the pipeline works, here's your day-to-day workflow:

### Making Changes

```bash
# 1. Create a feature branch
git checkout -b feature/add-orders-transform

# 2. Write your notebook, update resources/job YAML if needed

# 3. Validate locally (fast feedback)
databricks bundle validate

# 4. Commit and push
git add .
git commit -m "Add orders transform notebook and job"
git push -u origin feature/add-orders-transform

# 5. Open a Merge Request in GitLab
#    → Pipeline runs validate_bundle automatically
#    → If green, request review from your team

# 6. After approval, merge to main
#    → Pipeline runs validate + deploy automatically
#    → Your changes are now live in the dev workspace
```

### Quick Iteration (Bypassing CI for Dev Testing)

Sometimes you want to test a notebook change immediately without going through the full git workflow:

```bash
# Deploy directly from your local machine
databricks bundle deploy -t dev

# Run the job
databricks bundle run -t dev silver_sample_job
```

This is fine for development. The CI/CD pipeline is the *official* path — direct deploys are for quick iteration.

---

## Your Project Should Now Look Like This

```
silver-layer-project/
├── .git/
├── .gitignore
├── .gitlab-ci.yml
├── databricks.yml
├── resources/
│   └── job_silver_sample.yml
├── src/
│   └── notebooks/
│       └── transform_sample.sql
├── tests/                          (empty for now)
└── README.md                       (optional)
```

---

## What To Do Next

Now that the machinery works, you can focus on what you're good at — the actual data engineering:

1. **Add your real notebooks** to `src/notebooks/` — the SQL and Python that shreds `sql_variant` into silver tables.
2. **Add real job definitions** in `resources/` — one YAML file per job or logical grouping.
3. **Push through an MR** for each new transform — get the habit of the validate-on-MR, deploy-on-merge workflow.
4. **When you're ready for more environments**, revisit Docs 2 and 3 for the multi-target and multi-stage patterns.

---

## Quick Reference Card

| What You Want To Do | Command |
|---|---|
| Validate your config | `databricks bundle validate` |
| Deploy to dev | `databricks bundle deploy -t dev` |
| Run a job | `databricks bundle run -t dev <job_key>` |
| See what's deployed | `databricks bundle summary` |
| Tear down dev resources | `databricks bundle destroy -t dev` |
| Check CLI version | `databricks --version` |
| Push changes (triggers CI/CD) | `git push` |

---

## Glossary of Commands Used in This Guide

| Command | What It Does |
|---|---|
| `curl -fsSL ... \| sh` | Downloads and runs the CLI installer script |
| `databricks configure` | Sets up authentication interactively |
| `git init` | Initializes a new git repository |
| `git remote add origin <url>` | Links your local repo to GitLab |
| `mkdir -p` | Creates a directory (and parents) without errors if it exists |

---

## Sources

- [Databricks CLI Installation](https://docs.databricks.com/aws/en/dev-tools/cli/install)
- [Databricks DAB Configuration](https://docs.databricks.com/aws/en/dev-tools/bundles/settings)
- [GitLab CI/CD Variables](https://docs.gitlab.com/ee/ci/variables/)
- [Databricks CI/CD Best Practices](https://docs.databricks.com/aws/en/dev-tools/ci-cd/best-practices)
- [Step-by-step DAB + GitLab CI/CD](https://medium.com/@unarine.tshiwawa/a-step-by-step-story-deploying-a-machine-learning-project-using-databricks-asset-bundles-and-a7351be633bf)

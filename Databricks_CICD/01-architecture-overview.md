# Doc 1: Architecture Overview — How the Pieces Fit Together

## Who This Is For

You're a data engineer who writes great SQL and Python. You know Databricks. You can shred JSON into silver tables all day. But the *deployment and DevOps machinery* around your code? That's the part that feels foreign. This doc series fixes that.

---

## The Big Picture

There are exactly **four moving parts** in your stack. Here's what each one does and how they connect:

```
┌─────────────────────────────────────────────────────────────┐
│                     YOUR LAPTOP / IDE                       │
│                                                             │
│   You write:                                                │
│     - SQL notebooks / Python scripts (the actual work)      │
│     - databricks.yml  (tells Databricks what to deploy)     │
│     - .gitlab-ci.yml  (tells GitLab how to deploy it)       │
│                                                             │
└──────────────────────┬──────────────────────────────────────┘
                       │  git push
                       ▼
┌─────────────────────────────────────────────────────────────┐
│                     GITLAB REPO                             │
│                                                             │
│   Stores your code + config. When you push:                 │
│     1. GitLab CI reads .gitlab-ci.yml                       │
│     2. Spins up a runner (a temporary Linux VM)             │
│     3. Installs the Databricks CLI on that runner           │
│     4. Runs DAB commands (validate → deploy → run)          │
│                                                             │
└──────────────────────┬──────────────────────────────────────┘
                       │  databricks bundle deploy
                       ▼
┌─────────────────────────────────────────────────────────────┐
│                 DATABRICKS WORKSPACE (Dev)                  │
│                                                             │
│   Receives the deployed bundle:                             │
│     - Jobs / Workflows get created or updated               │
│     - Notebooks get synced to a workspace path              │
│     - Cluster configs get applied                           │
│     - DLT pipelines get registered (if you use them)        │
│                                                             │
│   Your silver layer logic runs here against Unity Catalog.  │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

That's it. **Four things: your code, GitLab, DAB config, Databricks.** Everything else is just detail within these four boxes.

---

## What Each Piece Actually Is

### 1. Your Code (Notebooks + Python/SQL files)

This is what you already know. The notebooks and scripts that read bronze `sql_variant` columns, parse the JSON, and write clean silver tables. Nothing changes about how you write this code — DAB and GitLab just give you a disciplined way to *ship* it.

Your code lives in your GitLab repo alongside the config files. Typical structure:

```
my-silver-project/
├── src/
│   └── notebooks/
│       ├── transform_orders.sql
│       ├── transform_customers.sql
│       └── transform_products.py
├── databricks.yml          ← DAB config (Doc 2)
├── .gitlab-ci.yml          ← CI/CD pipeline (Doc 3)
└── README.md
```

### 2. Databricks Asset Bundles (DAB) — `databricks.yml`

**What it is:** A YAML file that declares *what* should exist in your Databricks workspace. Think of it as infrastructure-as-code specifically for Databricks.

**What it replaces:** Manually clicking around the Databricks UI to create jobs, set schedules, configure clusters, or upload notebooks. Instead, you describe all of that in YAML, and the Databricks CLI makes it real.

**The mental model:** `databricks.yml` is a *manifest*. It says "here are my jobs, here are my notebooks, here's the cluster config, and here's where everything goes." When you run `databricks bundle deploy`, the CLI reads this manifest and creates/updates everything in your workspace to match it.

**Key things DAB manages:**

- **Jobs/Workflows** — the orchestration that runs your notebooks on a schedule or trigger
- **Notebook paths** — where your notebooks land in the workspace
- **Cluster configuration** — what compute your jobs use
- **DLT Pipelines** — if you use Delta Live Tables
- **Targets** — environment-specific overrides (dev vs. staging vs. prod)
- **Variables** — parameterized values that change per environment

We'll go deep on this in **Doc 2**.

### 3. GitLab CI/CD — `.gitlab-ci.yml`

**What it is:** A YAML file that tells GitLab what to do when you push code. It defines a *pipeline* — a sequence of automated steps.

**What it replaces:** You manually SSH-ing into a server, pulling code, and running deploy commands by hand. Instead, GitLab does this automatically every time you push.

**The mental model:** `.gitlab-ci.yml` is a *recipe*. It says "when code lands on this branch, run these steps in this order." Each step runs in a fresh Linux container (called a runner). The steps typically are:

1. **Validate** — check that your `databricks.yml` is syntactically correct
2. **Deploy** — push the bundle to your Databricks workspace
3. **Test** (optional) — run a smoke test or integration test

**Why it matters for you:** Without CI/CD, every deploy is manual and error-prone. With it, merging a merge request (MR) to `main` automatically deploys your updated silver layer logic. No more "did someone remember to upload the latest notebook?"

We'll go deep on this in **Doc 3**.

### 4. Databricks Workspace

This is where your code actually runs. You already know this environment. The only new concept is that DAB *manages* resources here declaratively — meaning the state of your workspace is driven by your YAML config, not by manual clicks.

When DAB deploys, it creates a **bundle state file** in your workspace that tracks what it has deployed. This is how it knows to update existing resources instead of creating duplicates.

---

## How They Connect — The Flow

Here's the lifecycle of a change, from your keyboard to running in Databricks:

```
 YOU                    GITLAB                 DATABRICKS
  │                       │                       │
  │  1. Write/edit code   │                       │
  │  2. Edit databricks.yml if needed             │
  │  3. git push          │                       │
  │ ─────────────────────>│                       │
  │                       │  4. CI pipeline starts│
  │                       │  5. Install CLI       │
  │                       │  6. bundle validate   │
  │                       │  7. bundle deploy ───────────────>│
  │                       │                       │  8. Jobs created/updated
  │                       │                       │  9. Notebooks synced
  │                       │  10. Pipeline passes  │
  │  11. See green ✓      │                       │
  │                       │                       │
```

**Steps 1-3** are the only things *you* do. Steps 4-10 happen automatically.

---

## Key Terminology Cheat Sheet

| Term | What It Means in Your Context |
|---|---|
| **Bundle** | Your entire project packaged up — code + config + metadata. Defined by `databricks.yml`. |
| **Target** | An environment within your bundle (e.g., `dev`, `staging`, `prod`). Each target can override settings like workspace URL or cluster size. |
| **Resource** | A Databricks object managed by your bundle — a job, a pipeline, a notebook path. |
| **Runner** | The temporary Linux VM that GitLab spins up to execute your CI/CD pipeline steps. |
| **Pipeline** | A GitLab CI/CD pipeline — the sequence of stages (validate, deploy, test) that run on push. |
| **Stage** | A phase within a pipeline. Stages run sequentially; jobs within a stage can run in parallel. |
| **Artifact** | A file produced by one CI/CD stage and consumed by another (e.g., a built wheel file). |
| **MR (Merge Request)** | GitLab's version of a pull request. Your team reviews code here before it hits `main`. |
| **Unity Catalog** | Databricks' governance layer. Your silver tables live here. DAB doesn't manage the catalog directly — your notebooks do via SQL. |

---

## What's Coming Next

| Doc | Topic | What You'll Learn |
|---|---|---|
| **Doc 2** | DAB Deep Dive | Every section of `databricks.yml`, what it does, and how to configure it for your silver layer work |
| **Doc 3** | GitLab CI/CD Pipeline | How to write `.gitlab-ci.yml`, set up authentication, and automate deployment |
| **Doc 4** | Bootstrapping Guide | Step-by-step commands to go from zero to a working pipeline on your machine |

---

## Sources & Further Reading

- [Databricks DAB Configuration Reference](https://docs.databricks.com/aws/en/dev-tools/bundles/reference)
- [Databricks CI/CD Best Practices](https://docs.databricks.com/aws/en/dev-tools/ci-cd/best-practices)
- [DAB Resource Types](https://docs.databricks.com/aws/en/dev-tools/bundles/resources)
- [DAB Project Templates](https://docs.databricks.com/aws/en/dev-tools/bundles/templates)
- [Streamlining Databricks Deployments with DABs and GitLab CI/CD](https://www.freshgravity.com/insights-blogs/streamlining-databricks-deployments/)

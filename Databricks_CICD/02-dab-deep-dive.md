# Doc 2: Databricks Asset Bundles (DAB) — Deep Dive

## What This Doc Covers

Everything about `databricks.yml` — what each section does, how to structure it for your silver layer work, and the mental model that makes it all click.

---

## The Core Idea

`databricks.yml` is a **declarative manifest**. You describe the *desired state* of your Databricks workspace, and the CLI makes it so. You never manually create jobs or upload notebooks again. You describe them in YAML, push to git, and CI/CD deploys them.

One rule: **there must be exactly one file named `databricks.yml` at the root of your project.** You can split config into multiple files using `include`, but the root file is the entry point.

---

## Anatomy of `databricks.yml`

Here's the full skeleton with every major section. Don't panic — we'll walk through each one.

```yaml
# ─── Identity ────────────────────────────────────────────
bundle:
  name: silver-layer-transforms

# ─── Additional config files (optional) ─────────────────
include:
  - "resources/*.yml"

# ─── Shared variables ───────────────────────────────────
variables:
  catalog_name:
    description: "Unity Catalog name"
    default: "dev_catalog"
  schema_name:
    description: "Target schema for silver tables"
    default: "silver"

# ─── What gets deployed ─────────────────────────────────
resources:
  jobs:
    silver_daily_refresh:
      name: "Silver Layer - Daily Refresh"
      tasks:
        - task_key: "transform_orders"
          notebook_task:
            notebook_path: "../src/notebooks/transform_orders.sql"
          existing_cluster_id: ${var.cluster_id}
        - task_key: "transform_customers"
          notebook_task:
            notebook_path: "../src/notebooks/transform_customers.sql"
          existing_cluster_id: ${var.cluster_id}
          depends_on:
            - task_key: "transform_orders"
      schedule:
        quartz_cron_expression: "0 0 6 * * ?"
        timezone_id: "America/Chicago"

# ─── Environment-specific settings ──────────────────────
targets:
  dev:
    mode: development
    default: true
    workspace:
      host: https://your-dev-workspace.cloud.databricks.com
    variables:
      catalog_name: "dev_catalog"
      cluster_id: "0407-123456-abcdef"
```

Now let's break each section down.

---

## Section-by-Section Walkthrough

### `bundle:` — Identity

```yaml
bundle:
  name: silver-layer-transforms
```

This is just the name of your bundle. It's used as a prefix when DAB creates resources in your workspace (e.g., job names get prefixed with `[dev yourname] silver-layer-transforms` in development mode). Keep it short and descriptive.

**That's it.** This section is simple. Just a name.

---

### `include:` — Splitting Config Across Files

```yaml
include:
  - "resources/*.yml"
  - "resources/jobs/*.yml"
```

As your project grows, stuffing everything into one YAML file gets painful. `include` lets you split resource definitions into separate files. The paths are relative to where `databricks.yml` lives.

**When to use this:** Once you have more than 2-3 jobs, break them into individual files under a `resources/` directory. Your project would look like:

```
my-silver-project/
├── databricks.yml              ← bundle, variables, targets
├── resources/
│   ├── job_orders.yml          ← just the orders job definition
│   ├── job_customers.yml       ← just the customers job definition
│   └── job_products.yml        ← just the products job definition
├── src/
│   └── notebooks/
│       ├── transform_orders.sql
│       ├── transform_customers.sql
│       └── transform_products.py
└── .gitlab-ci.yml
```

Each included file just contains a `resources:` block. Example `resources/job_orders.yml`:

```yaml
resources:
  jobs:
    silver_orders_refresh:
      name: "Silver - Orders Refresh"
      tasks:
        - task_key: "transform_orders"
          notebook_task:
            notebook_path: "../src/notebooks/transform_orders.sql"
          existing_cluster_id: ${var.cluster_id}
```

---

### `variables:` — Parameterization

```yaml
variables:
  catalog_name:
    description: "Unity Catalog name"
    default: "dev_catalog"
  schema_name:
    description: "Target schema for silver tables"
    default: "silver"
  cluster_id:
    description: "Cluster to run jobs on"
```

Variables let you avoid hardcoding values that change between environments. You reference them elsewhere in the YAML with `${var.variable_name}`.

**Key behaviors:**

- Variables with a `default` value use that default unless overridden by a target.
- Variables *without* a default are **required** — the CLI will error if you don't provide a value (either via target config, CLI flag, or environment variable).
- You can set variables from the command line: `databricks bundle deploy --var="cluster_id=0407-xxx"`
- You can set them via environment variables: `BUNDLE_VAR_cluster_id=0407-xxx`

**For your silver layer work, typical variables:**

| Variable | Why |
|---|---|
| `catalog_name` | Different Unity Catalog per environment |
| `schema_name` | Your silver schema name |
| `cluster_id` | Different clusters in dev vs. prod |
| `warehouse_id` | If using SQL warehouses for some tasks |

---

### `resources:` — The Heart of It

This is where you declare *what* Databricks objects your bundle manages. The most common resource type for your work is `jobs`.

#### Jobs

A job is a workflow — one or more tasks that run on a schedule or on-demand. Each task typically runs a notebook.

```yaml
resources:
  jobs:
    silver_daily_refresh:                          # ← internal key (your reference)
      name: "Silver Layer - Daily Refresh"         # ← display name in Databricks UI
      tags:
        team: "data-engineering"
        layer: "silver"

      # ── Job Clusters (defined once, reused across tasks) ──
      job_clusters:
        - job_cluster_key: "shared_cluster"
          new_cluster:
            spark_version: "14.3.x-scala2.12"
            node_type_id: "i3.xlarge"
            num_workers: 2
            spark_conf:
              "spark.databricks.sql.variant.enabled": "true"

      # ── Tasks (the actual work) ──
      tasks:
        - task_key: "transform_orders"
          job_cluster_key: "shared_cluster"
          notebook_task:
            notebook_path: "../src/notebooks/transform_orders.sql"
            base_parameters:
              catalog: ${var.catalog_name}
              schema: ${var.schema_name}

        - task_key: "transform_customers"
          job_cluster_key: "shared_cluster"
          notebook_task:
            notebook_path: "../src/notebooks/transform_customers.sql"
            base_parameters:
              catalog: ${var.catalog_name}
              schema: ${var.schema_name}
          depends_on:
            - task_key: "transform_orders"

        - task_key: "transform_products"
          job_cluster_key: "shared_cluster"
          notebook_task:
            notebook_path: "../src/notebooks/transform_products.py"
            base_parameters:
              catalog: ${var.catalog_name}
              schema: ${var.schema_name}
          depends_on:
            - task_key: "transform_orders"

      # ── Schedule ──
      schedule:
        quartz_cron_expression: "0 0 6 * * ?"     # 6 AM daily
        timezone_id: "America/Chicago"

      # ── Alerts ──
      email_notifications:
        on_failure:
          - your-team@company.com
```

**Things to notice:**

1. **`job_clusters`** — Define a cluster config once, reference it by key in each task. This way all tasks share the same cluster definition (and can share the same running cluster if they run sequentially).

2. **`depends_on`** — Controls task execution order. Tasks without dependencies run in parallel. In the example above, `transform_customers` and `transform_products` both wait for `transform_orders`, but can run in parallel with each other.

3. **`notebook_path`** — Paths are relative to the bundle root. The `../src/notebooks/` prefix means "go up one level from where the resource YAML file is, then into `src/notebooks/`." If your resource definition is in `databricks.yml` at the root, the path would just be `./src/notebooks/transform_orders.sql`.

4. **`base_parameters`** — These become widget values in your notebooks. Your notebook can read `catalog` and `schema` using `dbutils.widgets.get("catalog")` (Python) or `:catalog` / `${catalog}` (SQL, depending on your approach).

#### Notebook Paths — An Important Detail

When DAB deploys, it uploads your notebooks to your workspace. By default in development mode, they go to:

```
/Users/your.email@company.com/.bundle/<bundle-name>/dev/files/
```

You don't need to worry about this path — DAB handles it. Just know that `notebook_path` in your job config is relative to your local project structure, and DAB maps it to the correct workspace path automatically.

---

### `targets:` — Environment Configuration

Targets are how you define different environments. Right now you only need `dev`, but the structure makes it trivial to add more later.

```yaml
targets:
  dev:
    mode: development        # ← special mode, explained below
    default: true            # ← used when you don't specify a target
    workspace:
      host: https://your-dev-workspace.cloud.databricks.com
    variables:
      catalog_name: "dev_catalog"
      cluster_id: "0407-123456-abcdef"

  # ── Uncomment these when you're ready for more environments ──
  # staging:
  #   workspace:
  #     host: https://your-staging-workspace.cloud.databricks.com
  #   variables:
  #     catalog_name: "staging_catalog"
  #     cluster_id: "0407-654321-fedcba"
  #
  # prod:
  #   mode: production
  #   workspace:
  #     host: https://your-prod-workspace.cloud.databricks.com
  #   variables:
  #     catalog_name: "prod_catalog"
  #     cluster_id: "0407-111111-aaaaaa"
```

#### Development Mode (`mode: development`)

This is crucial. When a target has `mode: development`, DAB does several helpful things:

- **Prefixes resource names** with `[dev your.email]` so they don't collide with production resources.
- **Deploys notebooks to your personal folder** (`/Users/your.email/...`) instead of a shared location.
- **Sets jobs to unscheduled by default** — even if you defined a schedule, dev mode disables it so you don't accidentally run a cron job in dev.
- **Sets clusters to terminate quickly** to save costs.

This means you can safely deploy and test in dev without affecting anyone else or running up compute costs.

#### Production Mode (`mode: production`)

When you eventually add a prod target, `mode: production` enforces stricter rules: it requires a service principal (not a personal user) for deployment and deploys to shared workspace paths.

---

## How Variables Flow Through the System

This is the concept that ties it all together. Here's the flow:

```
databricks.yml          Target (dev)           Notebook
┌──────────────┐    ┌──────────────────┐    ┌──────────────────┐
│ variables:   │    │ targets:         │    │ -- In your SQL:  │
│   catalog:   │───>│   dev:           │───>│ USE CATALOG      │
│     default: │    │     variables:   │    │   ${catalog};    │
│     "dev_cat"│    │       catalog:   │    │ USE SCHEMA       │
│              │    │       "dev_cat"  │    │   ${schema};     │
│   schema:    │    │       ...        │    │                  │
│     default: │    │                  │    │ SELECT           │
│     "silver" │    │                  │    │   col1::string   │
│              │    │                  │    │ FROM bronze.raw  │
└──────────────┘    └──────────────────┘    └──────────────────┘
```

1. You define variables with defaults in the `variables:` section.
2. Targets can override those defaults for their specific environment.
3. Variables flow into job definitions via `${var.catalog_name}` syntax.
4. `base_parameters` passes them to notebooks as widget parameters.
5. Your notebooks read them and use them in SQL/Python.

---

## Common Patterns for Silver Layer Work

### Pattern 1: One Job Per Domain

If your bronze-to-silver transforms are independent domains (orders, customers, products), consider separate jobs:

```yaml
resources:
  jobs:
    silver_orders:
      name: "Silver - Orders"
      tasks:
        - task_key: "shred_orders"
          notebook_task:
            notebook_path: "./src/notebooks/transform_orders.sql"
          # ...

    silver_customers:
      name: "Silver - Customers"
      tasks:
        - task_key: "shred_customers"
          notebook_task:
            notebook_path: "./src/notebooks/transform_customers.sql"
          # ...
```

**Pros:** Independent scheduling, independent failure isolation.
**Cons:** More jobs to manage.

### Pattern 2: One Job, Many Tasks

If transforms have dependencies (customers depends on orders), a single multi-task job makes more sense:

```yaml
resources:
  jobs:
    silver_daily:
      name: "Silver - Daily Refresh"
      tasks:
        - task_key: "orders"
          # ...
        - task_key: "customers"
          depends_on: [{task_key: "orders"}]
        - task_key: "products"
          depends_on: [{task_key: "orders"}]
```

**Pros:** Dependency management built in, single execution to monitor.
**Cons:** One failure can block downstream tasks.

### Pattern 3: Using SQL Warehouse Tasks

If some of your transforms are pure SQL and don't need Spark, you can use a SQL warehouse instead of a cluster:

```yaml
tasks:
  - task_key: "simple_transform"
    sql_task:
      file:
        path: "./src/sql/simple_transform.sql"
      warehouse_id: ${var.warehouse_id}
```

This can be cheaper for lightweight transforms.

---

## DAB CLI Commands You'll Use

These are the commands that GitLab CI will run (and that you'll run locally during development):

| Command | What It Does |
|---|---|
| `databricks bundle init` | Scaffolds a new bundle project from a template |
| `databricks bundle validate` | Checks your YAML for syntax errors and invalid references |
| `databricks bundle deploy -t dev` | Deploys resources to the `dev` target workspace |
| `databricks bundle run -t dev silver_daily_refresh` | Triggers a job run in the `dev` target |
| `databricks bundle destroy -t dev` | Removes all deployed resources for a target (careful!) |
| `databricks bundle summary` | Shows what resources the bundle manages |

**Your local development loop:**

```bash
# 1. Edit your notebook or YAML
# 2. Validate
databricks bundle validate

# 3. Deploy to dev
databricks bundle deploy -t dev

# 4. Run the job to test
databricks bundle run -t dev silver_daily_refresh

# 5. Check results in Databricks UI, iterate
```

---

## File Layout — Recommended Structure

Here's the full recommended project layout for your silver layer work:

```
silver-layer-project/
│
├── databricks.yml                  # Bundle config: name, variables, targets
│
├── resources/                      # Job/pipeline definitions (included via include:)
│   ├── job_silver_orders.yml
│   ├── job_silver_customers.yml
│   └── job_silver_products.yml
│
├── src/
│   └── notebooks/
│       ├── transform_orders.sql    # Bronze → Silver: orders
│       ├── transform_customers.sql # Bronze → Silver: customers
│       └── transform_products.py   # Bronze → Silver: products
│
├── tests/                          # Integration tests (optional but recommended)
│   └── test_silver_orders.py
│
├── .gitlab-ci.yml                  # CI/CD pipeline definition (Doc 3)
│
└── README.md
```

---

## Gotchas and Tips

1. **YAML indentation matters.** Use 2 spaces, never tabs. A single wrong indent will cause cryptic errors.

2. **Notebook paths are relative to the YAML file they're defined in,** not the project root. If you split resources into `resources/job_orders.yml`, the notebook path needs to account for the extra directory level: `../src/notebooks/transform_orders.sql`.

3. **Development mode disables schedules.** This is intentional — you don't want dev jobs running on cron. To manually trigger: `databricks bundle run -t dev <job_key>`.

4. **`existing_cluster_id` vs. `job_clusters`:** Use `existing_cluster_id` if you have an always-on cluster. Use `job_clusters` to define ephemeral job clusters that spin up for the job and terminate after. Job clusters are more cost-efficient for scheduled workloads.

5. **Bundle state is stored in your workspace.** DAB creates a `.bundle/` directory in your workspace folder. Don't manually delete it — this is how DAB tracks what it has deployed.

6. **Validate early and often.** `databricks bundle validate` is fast and catches most config errors before you waste time deploying.

---

## Next Up

**Doc 3** covers the GitLab CI/CD side — how to write `.gitlab-ci.yml` to automate everything you just learned about DAB.

---

## Sources

- [Databricks DAB Configuration Settings](https://docs.databricks.com/aws/en/dev-tools/bundles/settings)
- [DAB Resource Types](https://docs.databricks.com/aws/en/dev-tools/bundles/resources)
- [DAB Configuration Reference](https://docs.databricks.com/aws/en/dev-tools/bundles/reference)
- [DAB Target Customization](https://www.vladsiv.com/posts/databricks-dab-target-customization)

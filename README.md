# Semantic View GitOps Demo

Version-control Snowflake **Semantic Views** with Git and deploy them automatically via GitHub Actions using the GA [`snowflakedb/snowflake-actions@v3`](https://github.com/snowflakedb/snowflake-actions) with secretless OIDC authentication. Includes a **Cortex Analyst evaluation quality gate** that fails the pipeline if NL-to-SQL accuracy drops below a threshold.

## How It Works

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  Developer edits semantic_views/tpch_revenue_analysis.yaml                    │
│  └─> Opens Pull Request                                                      │
│       └─> GitHub Actions validates YAML (dry-run)                            │
│            └─> PR merges to main                                             │
│                 └─> Deploys to SANDBOX_DEV (development)                      │
│                      └─> Evaluation runs (threshold: 70%)                     │
│                           └─> Ready to promote?                               │
│                                └─> Create GitHub Release                      │
│                                     └─> Deploys to SANDBOX (production)       │
│                                          └─> Evaluation runs (threshold: 80%) │
└──────────────────────────────────────────────────────────────────────────────┘
```

| Trigger | Target | Eval Threshold | Purpose |
|---------|--------|----------------|---------|
| Push to `main` | `SANDBOX_DEV.PUBLIC` | 70% | Iterate quickly in development |
| GitHub Release (tag) | `SANDBOX.PUBLIC` | 80% | Promote to production |
| Manual dispatch | Choice of `dev` or `prod` | Varies | Ad-hoc deploys |

- **PR validation**: [`SYSTEM$CREATE_SEMANTIC_VIEW_FROM_YAML(..., TRUE)`](https://docs.snowflake.com/en/user-guide/views-semantic/sql#creating-a-semantic-view-from-a-yaml-specification) confirms the YAML is structurally valid without deploying
- **Dev deploy (push to main)**: Deploys to `SANDBOX_DEV.PUBLIC` — fast iteration loop
- **Prod promotion (GitHub Release)**: Deploys to `SANDBOX.PUBLIC` — higher eval threshold, production-grade
- **Evaluation gate**: After deploy, [`EXECUTE_AI_EVALUATION`](https://docs.snowflake.com/en/sql-reference/functions/execute_ai_evaluation) runs verified queries through Cortex Analyst and checks `sql_correctness` accuracy
- **Auth**: [OIDC workload identity federation](https://docs.snowflake.com/en/user-guide/workload-identity-federation) — no stored secrets, short-lived tokens per run

## Repository Structure

```
├── semantic_views/
│   └── tpch_revenue_analysis.yaml   ← Semantic view + verified queries (source of truth)
├── scripts/
│   ├── deploy.sh                     ← Deploy/validate script
│   ├── evaluate.sh                   ← Cortex Analyst evaluation quality gate
│   └── setup_oidc.sql                ← One-time Snowflake OIDC setup
├── .github/workflows/
│   ├── validate.yml                  ← Runs on PRs (dry-run validation)
│   └── deploy.yml                    ← Runs on push to main (deploy + evaluate)
├── config.toml                       ← Snowflake CLI connection config
└── README.md
```

## Prerequisites

1. A Snowflake account with `SNOWFLAKE_SAMPLE_DATA` available
2. GitHub CLI (`gh`) authenticated
3. One-time OIDC trust setup (see below)

## Setup

### 1. Configure OIDC Trust in Snowflake

Run `scripts/setup_oidc.sql` as ACCOUNTADMIN. This creates a service user that trusts GitHub's OIDC provider:

```sql
CREATE OR REPLACE USER GITHUB_ACTIONS_SVC
  TYPE = SERVICE
  WORKLOAD_IDENTITY = (
    TYPE = OIDC
    ISSUER = 'https://token.actions.githubusercontent.com'
    SUBJECT = 'repo:<owner>/semantic-view-gitops-demo:ref:refs/heads/main'
  );
```

> See [Workload Identity Federation — OIDC subject formats](https://docs.snowflake.com/en/developer-guide/snowflake-cli/cicd/github-action#create-the-service-user) for subject claim variants (PR events, environments, etc.)

### 2. Set GitHub Secret

Only one secret is needed (no passwords or keys):

```bash
gh secret set SNOWFLAKE_ACCOUNT -b "YOUR_ACCOUNT_IDENTIFIER"
```

### 3. Push and Deploy

Any push to `main` that modifies `semantic_views/` triggers deployment to **DEV** automatically.

## Making Changes (Dev → Prod Workflow)

1. Edit `semantic_views/tpch_revenue_analysis.yaml`
2. Create a branch and open a PR
3. The **Validate** workflow checks your YAML compiles correctly
4. Merge — deploys to **SANDBOX_DEV.PUBLIC** (development)
5. Iterate until satisfied with the dev version
6. **Promote to production**: Create a [GitHub Release](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository) → deploys to **SANDBOX.PUBLIC** (production)

### Promoting to Production

```bash
# Tag the current state and create a release
gh release create v1.0.0 --title "Initial revenue analysis semantic view" --notes "First production release"
```

This triggers the deploy workflow targeting production (`SANDBOX.PUBLIC`) with the higher 80% eval threshold.

## Cortex Analyst Evaluation

The deploy pipeline includes an automated quality gate powered by [Cortex Analyst Evaluations](https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-analyst-evaluations).

### How It Works

1. **Verified queries** are defined in the YAML file alongside dimensions/metrics
2. After deploy, `scripts/evaluate.sh` triggers an evaluation run via [`EXECUTE_AI_EVALUATION`](https://docs.snowflake.com/en/sql-reference/functions/execute_ai_evaluation)
3. Cortex Analyst generates SQL for each verified query's question (with those queries temporarily removed from the model)
4. An LLM judge compares generated vs expected results (`sql_correctness` metric)
5. If accuracy < `EVAL_THRESHOLD` (default 80%), the workflow fails

### Configuring the Threshold

Set `EVAL_THRESHOLD` in the workflow environment:

```yaml
env:
  EVAL_THRESHOLD: "80"  # fail if accuracy < 80%
```

### Verified Queries

The `verified_queries:` section in the YAML serves dual purposes:
- **Runtime guidance**: Helps Cortex Analyst answer similar user questions more accurately
- **Evaluation ground truth**: Used to measure accuracy during CI/CD (temporarily excluded during eval)

Example:
```yaml
verified_queries:
  - name: "total_revenue_by_year"
    question: "What is the total revenue by year?"
    sql: |
      SELECT order_year, SUM(o_totalprice) AS total_revenue
      FROM __orders
      GROUP BY order_year
      ORDER BY order_year
```

> Note: SQL uses logical table names (`__orders`) prefixed with `__` and logical column names from the semantic view definition.

## Local Development

Validate locally before pushing:

```bash
./scripts/deploy.sh --dry-run
```

Deploy manually:

```bash
./scripts/deploy.sh
```

Run evaluation locally:

```bash
SNOWFLAKE_TARGET_SCHEMA=SANDBOX.PUBLIC ./scripts/evaluate.sh
```

## The Semantic View

This demo uses TPC-H sample data to create a revenue analysis semantic view with:

| Component | Details |
|-----------|---------|
| **Tables** | CUSTOMERS, ORDERS, LINE_ITEMS |
| **Dimensions** | customer_name, market_segment, order_date, order_year, order_status |
| **Metrics** | customer_count, order_average_value, average_line_items_per_order, total_revenue, total_discounted_revenue, average_discount_savings |
| **Facts** | discounted_price, line_item_id, count_line_items |
| **Verified Queries** | 10 Q&A pairs covering revenue, customers, orders, and discounts |

## Why YAML + Git?

- **Readable diffs** — reviewers see exactly which metrics/dimensions changed
- **Audit trail** — every change is a commit with author and timestamp
- **Safe deployments** — PR validation catches errors before they hit production
- **Quality gate** — Cortex Analyst evaluation catches semantic regressions
- **Rollback** — `git revert` undoes any bad deploy
- **Collaboration** — standard PR review workflow for data model changes

## Snowflake Features Used

| Feature | What It Does | Docs |
|---------|-------------|------|
| **Semantic Views** | Business-friendly semantic layer for Cortex Analyst; defines tables, relationships, dimensions, facts, and metrics in SQL or YAML | [Overview](https://docs.snowflake.com/en/user-guide/views-semantic/overview) · [SQL commands](https://docs.snowflake.com/en/user-guide/views-semantic/sql) · [CREATE SEMANTIC VIEW](https://docs.snowflake.com/en/sql-reference/sql/create-semantic-view) |
| **SYSTEM$CREATE_SEMANTIC_VIEW_FROM_YAML** | Creates (or validates) a semantic view from a YAML spec; `TRUE` as 3rd arg is a dry-run | [Docs](https://docs.snowflake.com/en/user-guide/views-semantic/sql#creating-a-semantic-view-from-a-yaml-specification) |
| **SYSTEM$READ_YAML_FROM_SEMANTIC_VIEW** | Exports an existing semantic view back to YAML — useful for seeding the YAML file from a view you built in the UI | [Docs](https://docs.snowflake.com/en/user-guide/views-semantic/sql#getting-the-yaml-specification-for-a-semantic-view) |
| **Cortex Analyst** | NL-to-SQL AI assistant that uses semantic views as its data model; this demo's semantic view is immediately queryable via Cortex Analyst | [Overview](https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-analyst) · [Quickstart](https://quickstarts.snowflake.com/guide/getting_started_with_cortex_analyst) |
| **Cortex Analyst Evaluations** | Measures SQL generation accuracy against verified queries using an LLM judge; tracks regressions across changes | [Docs](https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-analyst-evaluations) · [EXECUTE_AI_EVALUATION](https://docs.snowflake.com/en/sql-reference/functions/execute_ai_evaluation) |
| **Verified Query Repository (VQR)** | Golden Q&A pairs that guide Cortex Analyst at runtime and serve as ground truth for evaluations | [Docs](https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-analyst/verified-query-repository) |
| **Workload Identity Federation (OIDC)** | Allows GitHub Actions to authenticate to Snowflake with short-lived OIDC tokens — no static secrets needed | [WIF overview](https://docs.snowflake.com/en/user-guide/workload-identity-federation) · [GitHub OIDC guide](https://docs.snowflake.com/en/developer-guide/snowflake-cli/cicd/github-action#workload-identity-federation-wif-with-oidc) |
| **snowflakedb/snowflake-actions@v3** | GA GitHub Action that installs Snowflake CLI and configures OIDC auth in one step | [Marketplace](https://github.com/marketplace/actions/snowflake-actions) · [Repo](https://github.com/snowflakedb/snowflake-actions) · [Docs](https://docs.snowflake.com/en/developer-guide/snowflake-cli/cicd/github-action) |
| **Snowflake CLI (`snow`)** | CLI for deploying Snowflake objects; `snow sql -q` runs ad-hoc SQL from CI/CD | [Install](https://docs.snowflake.com/en/developer-guide/snowflake-cli/installation/installation) · [snow sql](https://docs.snowflake.com/en/developer-guide/snowflake-cli/command-reference/sql-commands) · [CI/CD integration](https://docs.snowflake.com/en/developer-guide/snowflake-cli/cicd/integrate-ci-cd) |
| **Authentication Policies** | Per-user or account-level policy controlling which auth methods are permitted; service users can be restricted to `WORKLOAD_IDENTITY` only | [Docs](https://docs.snowflake.com/en/user-guide/authentication-policy) |
| **Network Policies** | IP allowlist/blocklist on a user or account; attach a user-level policy to a CI service user to avoid blanket account restrictions | [Docs](https://docs.snowflake.com/en/user-guide/network-policy) |

## Further Reading

- [Configure CI/CD Integrations with Snowflake](https://www.snowflake.com/en/developers/guides/configure-cicd-integrations-with-snowflake) — step-by-step quickstart covering GitHub, GitLab, and Azure DevOps
- [DevOps with Snowflake](https://docs.snowflake.com/en/developer-guide/builders/devops-with-snowflake) — broader DevOps concepts: DCM, versioning, pipelines
- [CREATE OR ALTER SEMANTIC VIEW](https://docs.snowflake.com/en/sql-reference/sql/create-semantic-view) — idempotent DDL alternative to the YAML stored procedure approach
- [Semantic View YAML spec reference](https://docs.snowflake.com/en/user-guide/views-semantic/sql#creating-a-semantic-view-from-a-yaml-specification) — full YAML schema with all supported fields
- [Cortex Analyst — custom instructions](https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-analyst/custom-instructions) — add SQL generation hints and question categorization rules
- [Cortex Analyst — verified queries](https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-analyst/verified-query-repository) — add golden Q&A pairs to your semantic view to improve AI accuracy
- [Cortex Analyst evaluations](https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-analyst-evaluations) — measure and improve SQL generation accuracy

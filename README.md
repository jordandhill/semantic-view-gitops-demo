# Semantic View GitOps Demo

Version-control Snowflake **Semantic Views** with Git and deploy them automatically via GitHub Actions using the GA [`snowflakedb/snowflake-actions@v3`](https://github.com/snowflakedb/snowflake-actions) with secretless OIDC authentication.

## How It Works

```
┌─────────────────────────────────────────────────────────────────┐
│  Developer edits semantic_views/tpch_revenue_analysis.yaml      │
│  └─> Opens Pull Request                                        │
│       └─> GitHub Actions validates YAML (dry-run)              │
│            └─> PR merges to main                               │
│                 └─> GitHub Actions deploys to Snowflake         │
└─────────────────────────────────────────────────────────────────┘
```

- **PR validation**: [`SYSTEM$CREATE_SEMANTIC_VIEW_FROM_YAML`](https://docs.snowflake.com/en/user-guide/views-semantic/sql#creating-a-semantic-view-from-a-yaml-specification)`(..., TRUE)` confirms the YAML is structurally valid without deploying
- **Deploy on merge**: Same function without the dry-run flag creates/replaces the semantic view in `SANDBOX.PUBLIC`
- **Auth**: [OIDC workload identity federation](https://docs.snowflake.com/en/user-guide/workload-identity-federation) — no stored secrets, short-lived tokens per run

## Repository Structure

```
├── semantic_views/
│   └── tpch_revenue_analysis.yaml   ← Semantic view definition (source of truth)
├── scripts/
│   ├── deploy.sh                     ← Deploy/validate script
│   └── setup_oidc.sql                ← One-time Snowflake OIDC setup
├── .github/workflows/
│   ├── validate.yml                  ← Runs on PRs (dry-run validation)
│   └── deploy.yml                    ← Runs on push to main (deploys)
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

Any push to `main` that modifies `semantic_views/` triggers deployment automatically.

## Making Changes

1. Edit `semantic_views/tpch_revenue_analysis.yaml`
2. Create a branch and open a PR
3. The **Validate** workflow checks your YAML compiles correctly
4. Merge — the **Deploy** workflow pushes to Snowflake

## Local Development

Validate locally before pushing:

```bash
./scripts/deploy.sh --dry-run
```

Deploy manually:

```bash
./scripts/deploy.sh
```

## The Semantic View

This demo uses TPC-H sample data to create a revenue analysis semantic view with:

| Component | Details |
|-----------|---------|
| **Tables** | CUSTOMERS, ORDERS, LINE_ITEMS |
| **Dimensions** | customer_name, market_segment, order_date, order_year, order_status |
| **Metrics** | customer_count, order_average_value, average_line_items_per_order, total_revenue |
| **Facts** | discounted_price, line_item_id, count_line_items |

## Why YAML + Git?

- **Readable diffs** — reviewers see exactly which metrics/dimensions changed
- **Audit trail** — every change is a commit with author and timestamp
- **Safe deployments** — PR validation catches errors before they hit production
- **Rollback** — `git revert` undoes any bad deploy
- **Collaboration** — standard PR review workflow for data model changes

## Snowflake Features Used

| Feature | What It Does | Docs |
|---------|-------------|------|
| **Semantic Views** | Business-friendly semantic layer for Cortex Analyst; defines tables, relationships, dimensions, facts, and metrics in SQL or YAML | [Overview](https://docs.snowflake.com/en/user-guide/views-semantic/overview) · [SQL commands](https://docs.snowflake.com/en/user-guide/views-semantic/sql) · [CREATE SEMANTIC VIEW](https://docs.snowflake.com/en/sql-reference/sql/create-semantic-view) |
| **SYSTEM$CREATE_SEMANTIC_VIEW_FROM_YAML** | Creates (or validates) a semantic view from a YAML spec; `TRUE` as 3rd arg is a dry-run | [Docs](https://docs.snowflake.com/en/user-guide/views-semantic/sql#creating-a-semantic-view-from-a-yaml-specification) |
| **SYSTEM$READ_YAML_FROM_SEMANTIC_VIEW** | Exports an existing semantic view back to YAML — useful for seeding the YAML file from a view you built in the UI | [Docs](https://docs.snowflake.com/en/user-guide/views-semantic/sql#getting-the-yaml-specification-for-a-semantic-view) |
| **Workload Identity Federation (OIDC)** | Allows GitHub Actions to authenticate to Snowflake with short-lived OIDC tokens — no static secrets needed | [WIF overview](https://docs.snowflake.com/en/user-guide/workload-identity-federation) · [GitHub OIDC guide](https://docs.snowflake.com/en/developer-guide/snowflake-cli/cicd/github-action#workload-identity-federation-wif-with-oidc) |
| **snowflakedb/snowflake-actions@v3** | GA GitHub Action that installs Snowflake CLI and configures OIDC auth in one step | [Marketplace](https://github.com/marketplace/actions/snowflake-actions) · [Repo](https://github.com/snowflakedb/snowflake-actions) · [Docs](https://docs.snowflake.com/en/developer-guide/snowflake-cli/cicd/github-action) |
| **Snowflake CLI (`snow`)** | CLI for deploying Snowflake objects; `snow sql -q` runs ad-hoc SQL from CI/CD | [Install](https://docs.snowflake.com/en/developer-guide/snowflake-cli/installation/installation) · [snow sql](https://docs.snowflake.com/en/developer-guide/snowflake-cli/command-reference/sql-commands) · [CI/CD integration](https://docs.snowflake.com/en/developer-guide/snowflake-cli/cicd/integrate-ci-cd) |
| **Authentication Policies** | Per-user or account-level policy controlling which auth methods are permitted; service users can be restricted to `WORKLOAD_IDENTITY` only | [Docs](https://docs.snowflake.com/en/user-guide/authentication-policy) |
| **Network Policies** | IP allowlist/blocklist on a user or account; attach a user-level policy to a CI service user to avoid blanket account restrictions | [Docs](https://docs.snowflake.com/en/user-guide/network-policy) |
| **Cortex Analyst** | NL-to-SQL AI assistant that uses semantic views as its data model; this demo's semantic view is immediately queryable via Cortex Analyst | [Overview](https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-analyst) · [Quickstart](https://quickstarts.snowflake.com/guide/getting_started_with_cortex_analyst) |

## Further Reading

- [Configure CI/CD Integrations with Snowflake](https://www.snowflake.com/en/developers/guides/configure-cicd-integrations-with-snowflake) — step-by-step quickstart covering GitHub, GitLab, and Azure DevOps
- [DevOps with Snowflake](https://docs.snowflake.com/en/developer-guide/builders/devops-with-snowflake) — broader DevOps concepts: DCM, versioning, pipelines
- [CREATE OR ALTER SEMANTIC VIEW](https://docs.snowflake.com/en/sql-reference/sql/create-semantic-view) — idempotent DDL alternative to the YAML stored procedure approach
- [Semantic View YAML spec reference](https://docs.snowflake.com/en/user-guide/views-semantic/sql#creating-a-semantic-view-from-a-yaml-specification) — full YAML schema with all supported fields
- [Cortex Analyst — verified queries](https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-analyst/verified-queries) — add golden Q&A pairs to your semantic view to improve AI accuracy

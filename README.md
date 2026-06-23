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

- **PR validation**: `SYSTEM$CREATE_SEMANTIC_VIEW_FROM_YAML(..., TRUE)` confirms the YAML is structurally valid without deploying
- **Deploy on merge**: Same function without the dry-run flag creates/replaces the semantic view in `SANDBOX.PUBLIC`
- **Auth**: OIDC workload identity federation — no stored secrets, short-lived tokens per run

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

-- ============================================================
-- OIDC Trust Setup for GitHub Actions → Snowflake
-- Run this ONCE as ACCOUNTADMIN to enable secretless deployments
-- ============================================================

USE ROLE ACCOUNTADMIN;

-- 1. Create a service user that trusts GitHub's OIDC provider
--    The SUBJECT claim covers both push-to-main and pull_request events
CREATE OR REPLACE USER GITHUB_ACTIONS_SVC
  TYPE = SERVICE
  WORKLOAD_IDENTITY = (
    TYPE = OIDC
    ISSUER = 'https://token.actions.githubusercontent.com'
    SUBJECT = 'repo:jordandhill/semantic-view-gitops-demo:ref:refs/heads/main'
  );

-- 2. Create a role for CI/CD operations
CREATE ROLE IF NOT EXISTS CICD_SEMANTIC_VIEWS;
GRANT ROLE CICD_SEMANTIC_VIEWS TO USER GITHUB_ACTIONS_SVC;

-- 3. Grant privileges needed to deploy semantic views
GRANT USAGE ON DATABASE SANDBOX TO ROLE CICD_SEMANTIC_VIEWS;
GRANT USAGE ON SCHEMA SANDBOX.PUBLIC TO ROLE CICD_SEMANTIC_VIEWS;
GRANT CREATE SEMANTIC VIEW ON SCHEMA SANDBOX.PUBLIC TO ROLE CICD_SEMANTIC_VIEWS;
GRANT USAGE ON DATABASE SNOWFLAKE_SAMPLE_DATA TO ROLE CICD_SEMANTIC_VIEWS;
GRANT USAGE ON SCHEMA SNOWFLAKE_SAMPLE_DATA.TPCH_SF1 TO ROLE CICD_SEMANTIC_VIEWS;
GRANT SELECT ON ALL TABLES IN SCHEMA SNOWFLAKE_SAMPLE_DATA.TPCH_SF1 TO ROLE CICD_SEMANTIC_VIEWS;

-- 4. Grant warehouse usage for query execution
GRANT USAGE ON WAREHOUSE COMPUTE_G2_S TO ROLE CICD_SEMANTIC_VIEWS;

-- 5. Set the default role for the service user
ALTER USER GITHUB_ACTIONS_SVC SET DEFAULT_ROLE = CICD_SEMANTIC_VIEWS;

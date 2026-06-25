-- ============================================================
-- OIDC Trust Setup for GitHub Actions → Snowflake
-- Run this ONCE as ACCOUNTADMIN to enable secretless deployments
-- ============================================================

USE ROLE ACCOUNTADMIN;

-- 1. Create a service user that trusts GitHub's OIDC provider
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

-- SNOWFLAKE_SAMPLE_DATA is a shared database — requires IMPORTED PRIVILEGES
GRANT IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE_SAMPLE_DATA TO ROLE CICD_SEMANTIC_VIEWS;

-- 4. Grant warehouse usage for query execution
GRANT USAGE ON WAREHOUSE COMPUTE_G2_S TO ROLE CICD_SEMANTIC_VIEWS;

-- 5. Set defaults for the service user
ALTER USER GITHUB_ACTIONS_SVC SET DEFAULT_ROLE = CICD_SEMANTIC_VIEWS;
ALTER USER GITHUB_ACTIONS_SVC SET DEFAULT_WAREHOUSE = COMPUTE_G2_S;

-- 6. (Optional) If account has a restrictive network policy, create a
--    user-level policy allowing GitHub Actions runner IPs
CREATE OR REPLACE NETWORK POLICY GITHUB_ACTIONS_POLICY
  ALLOWED_IP_LIST = ('0.0.0.0/0')
  COMMENT = 'Allows GitHub Actions runners to connect (restrict in production)';
ALTER USER GITHUB_ACTIONS_SVC SET NETWORK_POLICY = GITHUB_ACTIONS_POLICY;

-- 7. (Optional) If account has a restrictive authentication policy,
--    create a user-level policy allowing workload identity
CREATE OR REPLACE AUTHENTICATION POLICY SANDBOX.PUBLIC.GITHUB_ACTIONS_AUTH_POLICY
  AUTHENTICATION_METHODS = (WORKLOAD_IDENTITY)
  COMMENT = 'Allows OIDC workload identity for GitHub Actions CI/CD';
ALTER USER GITHUB_ACTIONS_SVC SET AUTHENTICATION POLICY SANDBOX.PUBLIC.GITHUB_ACTIONS_AUTH_POLICY;

-- The subgraph's `SubgraphDeployment` figures, one row per deployment that ever had an allocation or
-- any signal (nuthatch#1160, group B: `api/subgraph-deployments`, `api/subgraph-fees-30d`,
-- `api/subgraph-search`, the subgraph OpenGraph image). Names live on IPFS behind graph-gns-nest's
-- metadata hashes; this view is the on-chain half and is joined to them in Lodestar.
--
-- `signalled_tokens` follows `lodestar_allocations`' signal CTE (net of the curation tax, plus query
-- fees collected into the pool, less burns). `query_fees_amount` is the indexers' net query fees on the
-- deployment, per the `fees` CTE below. `staked_tokens` is active allocation.
-- `created_at` is the first block anything touched the deployment: its first allocation or its first
-- signal, whichever came first; the subgraph dates it from its first appearance the same way.
-- `active_allocation_count` and `curator_count` are the lengths the gateway path counted (the latter
-- counting exited positions too, as the subgraph's list does).
-- `denied_since` is the latest RewardsManager denylist update's sinceBlock. An update with zero
-- clears denial; an allocation-level RewardsDenied event cannot answer deployment eligibility.
CREATE VIEW lodestar_deployments AS
WITH signal AS (
  SELECT dep, SUM(tok) AS signalled_tokens, MIN(ts) AS first_ts FROM (
    SELECT LOWER("subgraphDeploymentID") AS dep,  CAST(tokens AS HUGEINT) - CAST("curationTax" AS HUGEINT) AS tok, CAST(block_timestamp AS BIGINT) AS ts FROM curation__signalled
    UNION ALL SELECT LOWER("subgraphDeploymentID"), -CAST(tokens AS HUGEINT), CAST(block_timestamp AS BIGINT) FROM curation__burned
    UNION ALL SELECT LOWER("subgraphDeploymentID"),  CAST(tokens AS HUGEINT), CAST(block_timestamp AS BIGINT) FROM curation__collected
  ) GROUP BY 1
),
-- The subgraph's `queryFeesAmount` is what the deployment's indexers were paid, after the curators' cut:
-- `QueryFeesCollected.tokensCollected - tokensCurators - tokensCollected // 100` (the 1% protocol cut) for
-- the Horizon era, `RebateCollected.queryFees` before it. Summing curation `Collected` instead gave exactly
-- one ninth of the gateway's figure on every deployment measured (the curators' 10% against the 90%).
fees AS (
  SELECT dep, SUM(t) AS query_fees_amount FROM (
    SELECT LOWER("subgraphDeploymentId") AS dep, CAST("tokensCollected" AS HUGEINT) - CAST("tokensCurators" AS HUGEINT) - (CAST("tokensCollected" AS HUGEINT) // 100) AS t FROM subgraph_service__query_fees_collected
    UNION ALL SELECT LOWER("subgraphDeploymentID"), CAST("queryFees" AS HUGEINT) FROM staking_legacy__rebate_collected
    UNION ALL SELECT LOWER("subgraphDeploymentID"), CAST("rebateFees" AS HUGEINT) FROM staking_legacy__allocation_collected
  ) GROUP BY 1
),
allocs AS (
  SELECT LOWER(subgraph_deployment) AS dep,
         SUM(allocated_tokens) FILTER (WHERE status = 'Active') AS staked_tokens,
         COUNT(*) FILTER (WHERE status = 'Active')             AS active_allocation_count,
         MIN(created_at)                                        AS first_ts
  FROM lodestar_allocations GROUP BY 1
),
curators AS (
  -- every position ever, exited ones included: that is the length of the subgraph's `curatorSignals`
  SELECT LOWER(subgraph_deployment) AS dep, COUNT(*) AS curator_count FROM lodestar_curator_signals GROUP BY 1
),
denylist AS (
  SELECT dep, since_block FROM (
    SELECT LOWER("subgraphDeploymentID") AS dep,
           CAST("sinceBlock" AS BIGINT) AS since_block,
           ROW_NUMBER() OVER (PARTITION BY LOWER("subgraphDeploymentID") ORDER BY block_number DESC, log_index DESC) AS rank
    FROM rewards__rewards_denylist_updated
  ) WHERE rank = 1
),
deps AS (SELECT dep FROM signal UNION SELECT dep FROM allocs)
SELECT d.dep                                          AS id,
       COALESCE(s.signalled_tokens, 0)                AS signalled_tokens,
       COALESCE(a.staked_tokens, 0)                   AS staked_tokens,
       COALESCE(f.query_fees_amount, 0)               AS query_fees_amount,
       LEAST(COALESCE(s.first_ts, 9223372036854775807), COALESCE(a.first_ts, 9223372036854775807)) AS created_at,
       COALESCE(a.active_allocation_count, 0)         AS active_allocation_count,
       COALESCE(c.curator_count, 0)                   AS curator_count,
       NULLIF(dl.since_block, 0)                     AS denied_since
FROM deps d
LEFT JOIN signal s ON s.dep = d.dep
LEFT JOIN fees f ON f.dep = d.dep
LEFT JOIN allocs a ON a.dep = d.dep
LEFT JOIN curators c ON c.dep = d.dep
LEFT JOIN denylist dl ON dl.dep = d.dep;

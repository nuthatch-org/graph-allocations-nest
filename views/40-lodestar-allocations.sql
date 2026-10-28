-- Lodestar's `SubgraphAllocation` shape, served from events instead of the gateway (RFC-0011).
--
-- Maps one-for-one onto the interface at `lodestar/src/lib/ingest/allocations.ts:7`, so the route can
-- read this and stop calling `subgraphQuery`. Twelve of its thirteen fields come from two contracts;
-- the thirteenth is noted below and is the only thing this view guesses at, which it refuses to do.
CREATE VIEW lodestar_allocations AS
WITH created AS (
  SELECT "allocationId"           AS id,
         indexer,
         "subgraphDeploymentId"   AS subgraph_deployment,
         CAST(tokens AS HUGEINT)  AS allocated_tokens,
         CAST("currentEpoch" AS HUGEINT) AS created_at_epoch,
         block_timestamp          AS created_at,
         block_number             AS created_at_block
  FROM subgraph_service__allocation_created
),
-- `AllocationResized` changes the stake without opening or closing anything, so the current size is
-- the newest resize if there is one and the creation amount otherwise.
resized AS (
  SELECT "allocationId" AS id,
         CAST("newTokens" AS HUGEINT) AS allocated_tokens,
         ROW_NUMBER() OVER (PARTITION BY "allocationId" ORDER BY block_number DESC, log_index DESC) AS rn
  FROM subgraph_service__allocation_resized
),
closed AS (
  SELECT "allocationId"  AS id,
         block_timestamp AS closed_at,
         block_number    AS closed_at_block,
         -- decoded as the text 'true'/'false'; Boolean('false') is true in JavaScript, which is how every
         -- closed allocation read forceClosed on the nest path. Cast so the JSON carries a real boolean.
         CAST("forceClosed" AS BOOLEAN) AS force_closed
  FROM subgraph_service__allocation_closed
),
-- The POI lives here, not on `AllocationClosed` - which is where the subgraph's shape implies it
-- should be. Rewards are collected on close, so this is also the closest thing to a closing epoch.
-- Both eras. Legacy allocations were paid by `RewardsAssigned` (no POI on the event, no delegator
-- split); Horizon ones by `IndexingRewardsCollected`. The network's all-time rewards read 196M against
-- the gateway's 837M with the legacy era missing; with it, 837,303,089 GRT exact.
-- Horizon collects rewards on every POI, not once at close: one closed allocation had two collections
-- and the newest alone read 0.48 GRT against the gateway's 639.5. Amounts sum over the collections; the
-- POI and the epoch are the newest's.
rewards AS (
  SELECT id, poi, rewards_epoch,
         SUM(indexing_rewards) OVER (PARTITION BY id)           AS indexing_rewards,
         SUM(indexing_delegator_rewards) OVER (PARTITION BY id) AS indexing_delegator_rewards,
         ROW_NUMBER() OVER (PARTITION BY id ORDER BY block_number DESC, log_index DESC) AS rn
  FROM (
    SELECT "allocationId" AS id, poi, CAST("tokensRewards" AS HUGEINT) AS indexing_rewards,
           CAST("tokensDelegationRewards" AS HUGEINT) AS indexing_delegator_rewards, CAST("currentEpoch" AS HUGEINT) AS rewards_epoch,
           block_number, log_index
    FROM subgraph_service__indexing_rewards_collected
    UNION ALL
    SELECT "allocationID", NULL, CAST(amount AS HUGEINT), 0, CAST(epoch AS HUGEINT), block_number, log_index
    FROM rewards__rewards_assigned
  )
),
-- The subgraph's `queryFeesCollected` is the indexer's net: after the curators' share and the 1%
-- protocol cut, the cut truncated per event. Gross read 12.2% high on every deployment's 30-day fees.
-- Legacy: `RebateCollected.queryFees` (already net), and the pre-rebate `AllocationCollected` less its
-- curation fees.
fees AS (
  SELECT id, SUM(t) AS query_fees_collected FROM (
    SELECT "allocationId" AS id, CAST("tokensCollected" AS HUGEINT) - CAST("tokensCurators" AS HUGEINT) - (CAST("tokensCollected" AS HUGEINT) // 100) AS t FROM subgraph_service__query_fees_collected
    UNION ALL SELECT "allocationID", CAST("queryFees" AS HUGEINT) FROM staking_legacy__rebate_collected
    UNION ALL SELECT "allocationID", CAST("rebateFees" AS HUGEINT) FROM staking_legacy__allocation_collected
  ) GROUP BY 1
),
-- The subgraph's `subgraphDeployment.signalledTokens`, exactly: what a curator paid in **net of
-- the curation tax** (the tax is burned, it never reaches the pool), less what burns returned, plus
-- query fees `Collected` into the pool. The first version of this fold summed gross deposits and
-- knew nothing of `Collected`; measured against the subgraph on five deployments it was wrong on
-- four, and the residual was `curatorFeeRewards` to the wei on every one (nuthatch#1078).
signal AS (
  SELECT dep, SUM(tok) AS signalled_tokens FROM (
    SELECT "subgraphDeploymentID" AS dep,  CAST(tokens AS HUGEINT) - CAST("curationTax" AS HUGEINT) AS tok FROM curation__signalled
    UNION ALL
    SELECT "subgraphDeploymentID" AS dep, -CAST(tokens AS HUGEINT) AS tok FROM curation__burned
    UNION ALL
    SELECT "subgraphDeploymentID" AS dep,  CAST(tokens AS HUGEINT) AS tok FROM curation__collected
  ) GROUP BY 1
)
SELECT c.id,
       c.indexer,
       c.subgraph_deployment,
       COALESCE(s.signalled_tokens, 0)              AS signalled_tokens,
       COALESCE(r.allocated_tokens, c.allocated_tokens) AS allocated_tokens,
       c.created_at_epoch,
       c.created_at,
       cl.closed_at,
       -- The one field nothing carries. `AllocationClosed` has no epoch, so this is the epoch the
       -- rewards were collected in - which for a normal close is the same block. It is NULL rather
       -- than a guess when an allocation closed without collecting rewards.
       CASE WHEN cl.id IS NULL THEN NULL ELSE rw.rewards_epoch END AS closed_at_epoch,
       rw.poi,
       COALESCE(rw.indexing_rewards, 0)             AS indexing_rewards,
       -- the delegators' share of those rewards, the subgraph's `indexingDelegatorRewards` (nuthatch#1160)
       COALESCE(rw.indexing_delegator_rewards, 0)   AS indexing_delegator_rewards,
       COALESCE(f.query_fees_collected, 0)          AS query_fees_collected,
       CASE WHEN cl.id IS NULL THEN 'Active' ELSE 'Closed' END AS status,
       cl.force_closed,
       c.created_at_block,
       cl.closed_at_block
FROM created c
LEFT JOIN (SELECT * FROM resized WHERE rn = 1) r  ON r.id  = c.id
LEFT JOIN closed cl                                ON cl.id = c.id
LEFT JOIN (SELECT * FROM rewards WHERE rn = 1) rw  ON rw.id = c.id
LEFT JOIN fees f                                   ON f.id  = c.id
LEFT JOIN signal s                                 ON s.dep = c.subgraph_deployment;

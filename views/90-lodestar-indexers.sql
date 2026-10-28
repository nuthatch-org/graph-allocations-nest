-- Lodestar's `Indexer`, `DelegatedStake`, `Curator` and `Provision` shapes, folded from events
-- (nuthatch#1160, the surfaces #1078 left: `api/indexers`, `api/indexer/[address]`,
-- `api/indexer-stake-history`, `api/rewards-history`, `api/curators`, `api/provisions`,
-- `api/portfolio`, `api/apr-provenance`, `lib/refresh.ts`, the indexer OpenGraph image).
--
-- Every modelling choice here is the one `80-lodestar-network.sql` already made and measured against
-- the gateway, applied per entity instead of summed: stake nets deposits, withdrawals and legacy
-- slashing; a delegation leaves the pool at the *exit* event (`StakeDelegatedLocked` before Horizon,
-- `TokensUndelegated` after), not at withdrawal; "active" is shares, not tokens. Where this view has
-- to say something the network view did not, the paragraph above the CTE says what and why, and the
-- parity run against the subgraph arbitrates rather than the reasoning.
--
-- Units: `*_tokens` and `*_shares` are wei as HUGEINT; cuts are parts per million as the contracts
-- emit them; addresses are lower-cased; `id` follows the subgraph (the address, or `delegator-indexer`).

-- ---------------------------------------------------------------------------------------------
-- The per-indexer ledger: one row per event that moved an indexer's own stake or its delegation
-- pool, with the block time, so a caller can state either figure *as of any moment* by summing rows
-- up to it (`api/indexer-stake-history` wants 27 weekly points; the subgraph answered those with
-- block-pinned queries). `lodestar_indexers` sums this same ledger, so the two cannot disagree.
--
-- `pool_delta` follows the model measured exact against `getDelegationPool` on every indexer: the
-- delegation events themselves, the explicit pool additions, the legacy-era delegator reward share
-- computed per `RewardsAssigned` from the cut in force (contract rounding, skipped when the pool was
-- empty), and the silent share on legacy allocations closed after the upgrade. Thawing is not in
-- `pool_delta`: summed over every indexer that is the subgraph's `totalDelegatedTokens` to the wei.
-- The subgraph's per-indexer `delegatedTokens` *does* include thawing (P2P: 158,046,448 GRT, equal to
-- `getDelegationPool().tokens`), so `thawing_delta` runs beside it - up at `TokensUndelegated`, down
-- at `DelegatedTokensWithdrawn` - and an as-of caller adds the two for that figure.
-- ---------------------------------------------------------------------------------------------
CREATE VIEW lodestar_indexer_ledger AS
WITH horizon_start AS (SELECT MIN(block_number) AS bn FROM staking__horizon_stake_deposited),
pool_shares_series AS (
  SELECT sp, k, SUM(sh) OVER (PARTITION BY sp ORDER BY k ROWS UNBOUNDED PRECEDING) AS cum_shares FROM (
    SELECT LOWER(indexer) AS sp, block_number * 100000 + log_index AS k,  CAST(shares AS HUGEINT) AS sh FROM staking_legacy__stake_delegated
    UNION ALL SELECT LOWER(indexer), block_number * 100000 + log_index, -CAST(shares AS HUGEINT) FROM staking_legacy__stake_delegated_locked
    UNION ALL SELECT LOWER("serviceProvider"), block_number * 100000 + log_index,  CAST(shares AS HUGEINT) FROM staking__tokens_delegated
    UNION ALL SELECT LOWER("serviceProvider"), block_number * 100000 + log_index, -CAST(shares AS HUGEINT) FROM staking__tokens_undelegated
  )
),
cuts AS (SELECT LOWER(indexer) AS sp, CAST("indexingRewardCut" AS HUGEINT) AS cut, block_number * 100000 + log_index AS k FROM staking_legacy__delegation_parameters_updated),
legacy_reward_share AS (
  -- The cut and the pool shares in force at each reward: the newest `cuts` and `pool_shares_series`
  -- rows at or before its key. That was `ASOF JOIN` (a reward before any cut drops, as the inner
  -- join did) and `ASOF LEFT JOIN`, which only DuckDB spells; here each newest key is carried
  -- forward over the three streams in key order, a change at the reward's own key sorting first as
  -- `>=` had it, and the reward joins on that exact key. `k` is unique per event.
  SELECT r.sp, r.ts, r.bn, r.k, r.amount - r.amount * c.cut // 1000000 AS t
  FROM (
    SELECT sp, k, amount, ts, bn, ck, pk FROM (
      SELECT sp, k, amount, ts, bn, src,
             MAX(CASE WHEN src = 0 THEN k END) OVER (PARTITION BY sp ORDER BY k, src ROWS UNBOUNDED PRECEDING) AS ck,
             MAX(CASE WHEN src = 1 THEN k END) OVER (PARTITION BY sp ORDER BY k, src ROWS UNBOUNDED PRECEDING) AS pk
      FROM (
        SELECT sp, k, 0 AS src, CAST(NULL AS HUGEINT) AS amount, CAST(NULL AS BIGINT) AS ts, CAST(NULL AS UBIGINT) AS bn FROM cuts
        UNION ALL SELECT sp, k, 1, CAST(NULL AS HUGEINT), CAST(NULL AS BIGINT), CAST(NULL AS UBIGINT) FROM pool_shares_series
        UNION ALL SELECT LOWER(indexer), block_number * 100000 + log_index, 2, CAST(amount AS HUGEINT), CAST(block_timestamp AS BIGINT), block_number FROM rewards__rewards_assigned
      )
    ) WHERE src = 2
  ) r
  JOIN cuts c ON c.sp = r.sp AND c.k = r.ck
  LEFT JOIN pool_shares_series ps ON ps.sp = r.sp AND ps.k = r.pk
  WHERE r.bn < COALESCE((SELECT bn FROM horizon_start), 9223372036854775807) AND COALESCE(ps.cum_shares, 0) > 0
),
legacy_path_share AS (
  -- As `legacy_reward_share`, for rewards on the Horizon path to legacy allocations.
  SELECT h.sp, h.ts, h.bn, h.k, h.amount - h.amount * c.cut // 1000000 AS t
  FROM (
    SELECT sp, k, a, amount, ts, bn, ck, pk FROM (
      SELECT sp, k, a, amount, ts, bn, src,
             MAX(CASE WHEN src = 0 THEN k END) OVER (PARTITION BY sp ORDER BY k, src ROWS UNBOUNDED PRECEDING) AS ck,
             MAX(CASE WHEN src = 1 THEN k END) OVER (PARTITION BY sp ORDER BY k, src ROWS UNBOUNDED PRECEDING) AS pk
      FROM (
        SELECT sp, k, 0 AS src, CAST(NULL AS VARCHAR) AS a, CAST(NULL AS HUGEINT) AS amount, CAST(NULL AS BIGINT) AS ts, CAST(NULL AS UBIGINT) AS bn FROM cuts
        UNION ALL SELECT sp, k, 1, CAST(NULL AS VARCHAR), CAST(NULL AS HUGEINT), CAST(NULL AS BIGINT), CAST(NULL AS UBIGINT) FROM pool_shares_series
        UNION ALL SELECT LOWER(indexer), block_number * 100000 + log_index, 2, LOWER("allocationID"), CAST(amount AS HUGEINT), CAST(block_timestamp AS BIGINT), block_number FROM rewards__horizon_rewards_assigned
      )
    ) WHERE src = 2
  ) h
  JOIN cuts c ON c.sp = h.sp AND c.k = h.ck
  LEFT JOIN pool_shares_series ps ON ps.sp = h.sp AND ps.k = h.pk
  WHERE h.a IN (SELECT LOWER("allocationID") FROM staking_legacy__allocation_created) AND COALESCE(ps.cum_shares, 0) > 0
)
SELECT LOWER(indexer) AS indexer, CAST(block_timestamp AS BIGINT) AS ts, block_number, block_number * 100000 + log_index AS k, 'stake_deposited' AS kind,  CAST(tokens AS HUGEINT) AS stake_delta, CAST(0 AS HUGEINT) AS pool_delta, CAST(0 AS HUGEINT) AS shares_delta, CAST(0 AS HUGEINT) AS thawing_delta FROM staking_legacy__stake_deposited
UNION ALL SELECT LOWER(indexer), CAST(block_timestamp AS BIGINT), block_number, block_number * 100000 + log_index, 'stake_withdrawn', -CAST(tokens AS HUGEINT), 0, 0, 0 FROM staking_legacy__stake_withdrawn
UNION ALL SELECT LOWER(indexer), CAST(block_timestamp AS BIGINT), block_number, block_number * 100000 + log_index, 'stake_slashed',   -CAST(tokens AS HUGEINT), 0, 0, 0 FROM staking_legacy__stake_slashed
UNION ALL SELECT LOWER("serviceProvider"), CAST(block_timestamp AS BIGINT), block_number, block_number * 100000 + log_index, 'stake_deposited',  CAST(tokens AS HUGEINT), 0, 0, 0 FROM staking__horizon_stake_deposited
UNION ALL SELECT LOWER("serviceProvider"), CAST(block_timestamp AS BIGINT), block_number, block_number * 100000 + log_index, 'stake_withdrawn', -CAST(tokens AS HUGEINT), 0, 0, 0 FROM staking__horizon_stake_withdrawn
UNION ALL SELECT LOWER("serviceProvider"), CAST(block_timestamp AS BIGINT), block_number, block_number * 100000 + log_index, 'stake_slashed',   -CAST(tokens AS HUGEINT), 0, 0, 0 FROM staking__provision_slashed
-- delegation pool
UNION ALL SELECT LOWER(indexer), CAST(block_timestamp AS BIGINT), block_number, block_number * 100000 + log_index, 'delegated',   0,  CAST(tokens AS HUGEINT),  CAST(shares AS HUGEINT), 0 FROM staking_legacy__stake_delegated
UNION ALL SELECT LOWER(indexer), CAST(block_timestamp AS BIGINT), block_number, block_number * 100000 + log_index, 'undelegated', 0, -CAST(tokens AS HUGEINT), -CAST(shares AS HUGEINT), 0 FROM staking_legacy__stake_delegated_locked
UNION ALL SELECT LOWER("serviceProvider"), CAST(block_timestamp AS BIGINT), block_number, block_number * 100000 + log_index, 'delegated',   0,  CAST(tokens AS HUGEINT),  CAST(shares AS HUGEINT), 0 FROM staking__tokens_delegated
UNION ALL SELECT LOWER("serviceProvider"), CAST(block_timestamp AS BIGINT), block_number, block_number * 100000 + log_index, 'undelegated', 0, -CAST(tokens AS HUGEINT), -CAST(shares AS HUGEINT), CAST(tokens AS HUGEINT) FROM staking__tokens_undelegated
UNION ALL SELECT LOWER("serviceProvider"), CAST(block_timestamp AS BIGINT), block_number, block_number * 100000 + log_index, 'pool_added',  0,  CAST(tokens AS HUGEINT), 0, 0 FROM staking__tokens_to_delegation_pool_added
UNION ALL SELECT LOWER("serviceProvider"), CAST(block_timestamp AS BIGINT), block_number, block_number * 100000 + log_index, 'pool_slashed', 0, -CAST(tokens AS HUGEINT), 0, 0 FROM staking__delegation_slashed
UNION ALL SELECT LOWER(indexer), CAST(block_timestamp AS BIGINT), block_number, block_number * 100000 + log_index, 'rebate_delegation_rewards', 0, CAST("delegationRewards" AS HUGEINT), 0, 0 FROM staking_legacy__rebate_collected
UNION ALL SELECT LOWER(indexer), CAST(block_timestamp AS BIGINT), block_number, block_number * 100000 + log_index, 'rebate_delegation_fees',    0, CAST("delegationFees" AS HUGEINT)   , 0, 0 FROM staking_legacy__rebate_claimed
UNION ALL SELECT LOWER("serviceProvider"), CAST(block_timestamp AS BIGINT), block_number, block_number * 100000 + log_index, 'withdrawn', 0, 0, 0, -CAST(tokens AS HUGEINT) FROM staking__delegated_tokens_withdrawn
UNION ALL SELECT sp, ts, bn, k, 'legacy_reward_share', 0, t, 0, 0 FROM legacy_reward_share
UNION ALL SELECT sp, ts, bn, k, 'legacy_path_share', 0, t, 0, 0 FROM legacy_path_share;

-- ---------------------------------------------------------------------------------------------
-- Per-indexer stake, delegation pool, cuts, rewards, fees, registry and provisions.
-- ---------------------------------------------------------------------------------------------
CREATE VIEW lodestar_indexers AS
WITH
-- Own stake and the delegation pool are sums over `lodestar_indexer_ledger`, so this view and any
-- as-of query over the ledger state the same figures. The ledger's header says what is in each.
-- **One pass over the ledger, not two.** These were two CTEs, `stake` and `pool_adjust`, each with
-- its own `GROUP BY` over `lodestar_indexer_ledger`. Nothing materialises a view, so that is the
-- whole ledger - sixteen unioned event streams and two ASOF joins over a windowed share series -
-- computed twice per request. Measured on the production nest, 2026-09-06: two folds 3.90 s, one
-- fold 2.13 s, for the identical answer. The `pool_adjust` half becomes a FILTER on the same
-- aggregate, which is what it always was.
stake AS (
  SELECT indexer AS sp, SUM(stake_delta) AS staked_tokens,
         MIN(ts) FILTER (WHERE stake_delta > 0) AS created_at,
         MIN(block_number) FILTER (WHERE stake_delta > 0) AS created_at_block,
         SUM(pool_delta) FILTER (WHERE kind NOT IN ('delegated', 'undelegated')) AS pool_rewards_added
  FROM lodestar_indexer_ledger GROUP BY 1
),
-- Locked (thawing) own stake. Both `StakeLocked` and `HorizonStakeLocked` carry the *total* locked
-- amount and its release time, not a delta, so the newest event is the state - unless a withdrawal
-- came after it, which empties the lock. `thawing_period` on Horizon is per provision; this is the
-- legacy-shaped `lockedTokens` / `lockedUntil` the indexer pages show.
lock_events AS (
  SELECT LOWER(indexer) AS sp, CAST(tokens AS HUGEINT) AS tokens, CAST("until" AS HUGEINT) AS until_block, block_number AS bn, log_index AS li FROM staking_legacy__stake_locked
  UNION ALL SELECT LOWER("serviceProvider"), CAST(tokens AS HUGEINT), CAST("until" AS HUGEINT), block_number, log_index FROM staking__horizon_stake_locked
),
withdraw_events AS (
  SELECT LOWER(indexer) AS sp, block_number AS bn, log_index AS li FROM staking_legacy__stake_withdrawn
  UNION ALL SELECT LOWER("serviceProvider"), block_number, log_index FROM staking__horizon_stake_withdrawn
),
locked AS (
  SELECT l.sp,
         CASE WHEN w.bn IS NULL OR (l.bn, l.li) > (w.bn, w.li) THEN l.tokens ELSE 0 END AS locked_tokens,
         CASE WHEN w.bn IS NULL OR (l.bn, l.li) > (w.bn, w.li) THEN l.until_block ELSE NULL END AS locked_until
  FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY sp ORDER BY bn DESC, li DESC) AS rn FROM lock_events) l
  LEFT JOIN (SELECT sp, MAX(bn) AS bn, MAX(li) AS li FROM withdraw_events GROUP BY 1) w ON w.sp = l.sp
  WHERE l.rn = 1
),
-- Delegation, per (delegator, indexer), exit at the exit event. Identical to the network view's
-- fold, kept per pair so `lodestar_delegator_stakes` below and the pool here cannot disagree.
delegation AS (
  SELECT delegator, sp, SUM(tok) AS net_tokens, SUM(sh) AS net_shares FROM (
    SELECT LOWER(delegator) AS delegator, LOWER(indexer) AS sp,            CAST(tokens AS HUGEINT) AS tok,  CAST(shares AS HUGEINT) AS sh FROM staking_legacy__stake_delegated
    UNION ALL SELECT LOWER(delegator), LOWER(indexer),                     -CAST(tokens AS HUGEINT),        -CAST(shares AS HUGEINT)      FROM staking_legacy__stake_delegated_locked
    UNION ALL SELECT LOWER(delegator), LOWER("serviceProvider"),            CAST(tokens AS HUGEINT),         CAST(shares AS HUGEINT)      FROM staking__tokens_delegated
    UNION ALL SELECT LOWER(delegator), LOWER("serviceProvider"),           -CAST(tokens AS HUGEINT),        -CAST(shares AS HUGEINT)      FROM staking__tokens_undelegated
  ) GROUP BY 1, 2
),
pool AS (
  SELECT sp,
         SUM(net_tokens)                                     AS delegated_net,
         SUM(net_shares)                                     AS delegator_shares,
         COUNT(DISTINCT delegator) FILTER (WHERE net_shares > 0) AS delegator_count
  FROM delegation GROUP BY 1
),
-- Undelegated and not yet withdrawn: the subgraph's `delegatedThawingTokens`, which is a Horizon
-- quantity (`pool.tokensThawing`) and is exit minus release over Horizon events only. Measured against
-- `getDelegationPool` on two indexers: 8,769 and 0 GRT, both exact. Legacy undelegations that were
-- never withdrawn are not thawing - they sit in the delegator's `tokensLocked` forever, 1.2M GRT on
-- one indexer - so they are carried in their own column and kept out of this one.
thawing AS (
  SELECT sp, GREATEST(SUM(t), 0) AS delegated_thawing_tokens, GREATEST(SUM(l), 0) AS legacy_locked_unwithdrawn FROM (
    SELECT LOWER("serviceProvider") AS sp,  CAST(tokens AS HUGEINT) AS t, CAST(0 AS HUGEINT) AS l FROM staking__tokens_undelegated
    UNION ALL SELECT LOWER("serviceProvider"), -CAST(tokens AS HUGEINT), 0 FROM staking__delegated_tokens_withdrawn
    UNION ALL SELECT LOWER(indexer), 0,  CAST(tokens AS HUGEINT) FROM staking_legacy__stake_delegated_locked
    UNION ALL SELECT LOWER(indexer), 0, -CAST(tokens AS HUGEINT) FROM staking__stake_delegated_withdrawn
  ) GROUP BY 1
),
-- Active allocations. The Horizon ones come from `lodestar_allocations` so the two surfaces share one
-- definition. A legacy allocation still open today is one that was created before the upgrade and
-- neither closed under either legacy `AllocationClosed` overload nor migrated into the subgraph
-- service (a migrated one is the service's to close, and is counted there).
legacy_open AS (
  SELECT LOWER(indexer) AS sp, CAST(tokens AS HUGEINT) AS tokens
  FROM staking_legacy__allocation_created c
  WHERE c."allocationID" NOT IN (SELECT "allocationID" FROM staking_legacy__allocation_closed_7203)
    AND c."allocationID" NOT IN (SELECT "allocationID" FROM staking_legacy__allocation_closed_f672)
    AND c."allocationID" NOT IN (SELECT "allocationId" FROM subgraph_service__legacy_allocation_migrated)
),
allocated AS (
  SELECT sp, SUM(tokens) AS allocated_tokens, COUNT(*) AS allocation_count FROM (
    SELECT LOWER(indexer) AS sp, allocated_tokens AS tokens FROM lodestar_allocations WHERE status = 'Active'
    UNION ALL SELECT sp, tokens FROM legacy_open
  ) GROUP BY 1
),
-- Delegation cuts, parts per million, newest of either era wins. Horizon sets them per payment type:
-- 0 = QueryFee, 1 = IndexingFee, 2 = IndexingRewards (`IGraphPayments.PaymentTypes`), and per
-- verifier; the subgraph reports the subgraph service's, and that is the only verifier that has set
-- any, so no filter is applied and the parity run will say if that stops being true.
cut_events AS (
  SELECT LOWER(indexer) AS sp, 'indexing' AS kind, CAST("indexingRewardCut" AS HUGEINT) AS cut, block_number AS bn, log_index AS li, block_timestamp AS ts, 'legacy' AS era FROM staking_legacy__delegation_parameters_updated
  UNION ALL SELECT LOWER(indexer), 'query',    CAST("queryFeeCut" AS HUGEINT),       block_number, log_index, block_timestamp, 'legacy' FROM staking_legacy__delegation_parameters_updated
  -- Horizon's `feeCut` is the share that goes to DELEGATORS (HorizonStaking `_delegationFeeCut`); the
  -- legacy cut, and the subgraph's field, is the share the indexer keeps. Measured on 8107: P2P's
  -- queryFeeCut read 0 here against 1,000,000 on the gateway, Ellipfra's 570,000 against 430,000.
  UNION ALL SELECT LOWER("serviceProvider"), CASE WHEN CAST("paymentType" AS INTEGER) = 2 THEN 'indexing' WHEN CAST("paymentType" AS INTEGER) = 0 THEN 'query' ELSE 'other' END,
                   1000000 - CAST("feeCut" AS HUGEINT), block_number, log_index, block_timestamp, 'horizon' FROM staking__delegation_fee_cut_set
),
-- An indexer with a provision is on Horizon, where the legacy parameters no longer apply: its cut is
-- the newest `DelegationFeeCutSet`, or "keeps everything" if none was set. 13 indexers carried a legacy
-- 800,000 or 750,000 here against the gateway's 1,000,000. Without a provision the legacy value stands.
cuts AS (
  SELECT c.sp,
         MAX(c.cut) FILTER (WHERE c.kind = 'indexing' AND c.rn = 1) AS indexing_reward_cut,
         MAX(c.cut) FILTER (WHERE c.kind = 'query'    AND c.rn = 1) AS query_fee_cut,
         MAX(c.ts)                                                  AS last_delegation_parameter_update
  FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY sp, kind ORDER BY bn DESC, li DESC) AS rn FROM cut_events
        WHERE era = 'horizon' OR sp NOT IN (SELECT LOWER("serviceProvider") FROM staking__provision_created)) c
  GROUP BY 1
),
-- Indexing rewards assigned, both eras; the subgraph's `rewardsEarned` is the gross figure before the
-- delegators' share, which is what `RewardsAssigned.amount` is.
rewards AS (
  SELECT sp, SUM(t) AS rewards_earned FROM (
    SELECT LOWER(indexer) AS sp, CAST(amount AS HUGEINT) AS t FROM rewards__rewards_assigned
    UNION ALL SELECT LOWER(indexer), CAST(amount AS HUGEINT) FROM rewards__horizon_rewards_assigned
  ) GROUP BY 1
),
-- Query fees, the indexer's net across three mechanisms: `AllocationCollected.rebateFees` (oldest; its
-- `tokens` is gross of both curation and the protocol tax, which read 17 indexers high),
-- `RebateCollected.queryFees` (the rebate era), and the subgraph service's `QueryFeesCollected`.
fees AS (
  SELECT sp, SUM(t) AS query_fees_collected FROM (
    SELECT LOWER(indexer) AS sp, CAST("rebateFees" AS HUGEINT) AS t FROM staking_legacy__allocation_collected
    UNION ALL SELECT LOWER(indexer), CAST("queryFees" AS HUGEINT) FROM staking_legacy__rebate_collected
    -- net of the curators' share and the 1% protocol cut, the subgraph's figure (gross read 3.5% high)
    UNION ALL SELECT LOWER("serviceProvider"), CAST("tokensCollected" AS HUGEINT) - CAST("tokensCurators" AS HUGEINT) - (CAST("tokensCollected" AS HUGEINT) // 100) FROM subgraph_service__query_fees_collected
  ) GROUP BY 1
),
-- Service registry: the newest of register / unregister per indexer is the state.
registry AS (
  SELECT sp, CASE WHEN kind = 'reg' THEN url ELSE NULL END AS url,
             CASE WHEN kind = 'reg' THEN geohash ELSE NULL END AS geohash
  FROM (
    SELECT LOWER(indexer) AS sp, 'reg' AS kind, url, geohash, block_number AS bn, log_index AS li,
           ROW_NUMBER() OVER (PARTITION BY LOWER(indexer) ORDER BY block_number DESC, log_index DESC) AS rn
    FROM (
      SELECT indexer, url, geohash, block_number, log_index FROM service_registry__service_registered
      UNION ALL SELECT indexer, NULL, NULL, block_number, log_index FROM service_registry__service_unregistered
      -- Horizon indexers register with the SubgraphService, whose event carries abi.encode(string url,
      -- string geohash, address rewardsDestination) as `data`: three head words, then each string as a
      -- length word and padded bytes. 14 of 184 indexers had no legacy registration and read url null.
      -- `geohash` is read from the same row one level up, where a LATERAL used to reach back for it.
      UNION ALL SELECT sp, url, decode(from_hex(substr(h, 257 + ((ulen + 31) // 32) * 64 + 64, glen * 2))) AS geohash,
                       block_number, log_index FROM (
        SELECT sp, block_number, log_index, ulen, h,
               decode(from_hex(substr(h, 257, ulen * 2))) AS url,
               CAST(('0x' || substr(h, 257 + ((ulen + 31) // 32) * 64, 64)) AS BIGINT) AS glen
        FROM (SELECT "serviceProvider" AS sp, block_number, log_index, substr(data, 3) AS h,
                     CAST(('0x' || substr(substr(data, 3), 193, 64)) AS BIGINT) AS ulen
              FROM subgraph_service__service_provider_registered)
      ) x
    )
  ) WHERE rn = 1
),
-- Provisioned stake across every verifier; `lodestar_provisions` below has it per verifier.
provisioned AS (
  SELECT sp, SUM(t) AS provisioned_tokens FROM (
    SELECT LOWER("serviceProvider") AS sp,  CAST(tokens AS HUGEINT) AS t FROM staking__provision_created
    UNION ALL SELECT LOWER("serviceProvider"),  CAST(tokens AS HUGEINT) FROM staking__provision_increased
    UNION ALL SELECT LOWER("serviceProvider"), -CAST(tokens AS HUGEINT) FROM staking__tokens_deprovisioned
    UNION ALL SELECT LOWER("serviceProvider"), -CAST(tokens AS HUGEINT) FROM staking__provision_slashed
  ) GROUP BY 1
)
SELECT s.sp                                                     AS id,
       s.staked_tokens,
       COALESCE(l.locked_tokens, 0)                             AS locked_tokens,
       l.locked_until,
       -- The subgraph's `delegatedTokens` is the whole pool, thawing included: it read 158,046,448 GRT for
       -- P2P against `getDelegationPool().tokens` of exactly that, while the pool net of its 38,093,038 GRT
       -- thawing was what this column held. `delegated_thawing_tokens` beside it is the thawing part.
       COALESCE(p.delegated_net, 0) + COALESCE(s.pool_rewards_added, 0) + COALESCE(th.delegated_thawing_tokens, 0) AS delegated_tokens,
       COALESCE(p.delegated_net, 0)                             AS delegated_net,
       COALESCE(s.pool_rewards_added, 0)                       AS delegated_pool_rewards,
       COALESCE(p.delegator_shares, 0)                          AS delegator_shares,
       COALESCE(p.delegator_count, 0)                           AS delegator_count,
       COALESCE(th.delegated_thawing_tokens, 0)                 AS delegated_thawing_tokens,
       COALESCE(th.legacy_locked_unwithdrawn, 0)                AS legacy_locked_unwithdrawn,
       COALESCE(a.allocated_tokens, 0)                          AS allocated_tokens,
       COALESCE(a.allocation_count, 0)                          AS allocation_count,
       -- no cut ever set means the indexer keeps everything: Horizon's feeCut defaults to 0 for
       -- delegators, which the subgraph reports as 1,000,000 (one indexer read 0 here against that)
       COALESCE(c.indexing_reward_cut, 1000000)                 AS indexing_reward_cut,
       COALESCE(c.query_fee_cut, 1000000)                       AS query_fee_cut,
       c.last_delegation_parameter_update,
       COALESCE(r.rewards_earned, 0)                            AS rewards_earned,
       COALESCE(f.query_fees_collected, 0)                      AS query_fees_collected,
       COALESCE(pr.provisioned_tokens, 0)                       AS provisioned_tokens,
       g.url,
       g.geohash,
       s.created_at,
       s.created_at_block
FROM stake s
LEFT JOIN locked      l  ON l.sp  = s.sp
LEFT JOIN pool        p  ON p.sp  = s.sp
LEFT JOIN thawing     th ON th.sp = s.sp
LEFT JOIN allocated   a  ON a.sp  = s.sp
LEFT JOIN cuts        c  ON c.sp  = s.sp
LEFT JOIN rewards     r  ON r.sp  = s.sp
LEFT JOIN fees        f  ON f.sp  = s.sp
LEFT JOIN registry    g  ON g.sp  = s.sp
LEFT JOIN provisioned pr ON pr.sp = s.sp;

-- ---------------------------------------------------------------------------------------------
-- Per (delegator, indexer): the subgraph's `DelegatedStake`, including its accounting.
--
-- Shares are exact and were measured against `getDelegation` (top 60, all equal). The token value
-- of a position is its share of the pool, `shares * pool_tokens / pool_shares`, as the contracts
-- value it. The rest follows `staking.ts` / `horizonStaking.ts` in the network subgraph:
--   * `personal_exchange_rate` is the delegator's weighted-average price per share, updated on every
--     delegation as (rate * shares + tokens_in) / (shares + shares_in), unchanged by undelegation;
--   * `realized_rewards` accrues on every undelegation as tokens_out - shares_out * rate, i.e. what
--     the position was worth at exit minus what it cost, and `TokensUndelegated.tokens` *is* the
--     exit value so no pool rate is needed.
-- That is a sequential fold per position, done with `list_reduce` over the position's events in
-- block order; the rate and realized rewards are DOUBLEs, which at 1e24 wei is a 1e-10 GRT error,
-- the subgraph's own BigDecimals are truncated to 18 places, and no on-chain oracle exists for either
-- (they are bookkeeping, not state). `locked_tokens` is undelegated and not yet withdrawn, both eras;
-- `locked_until` is the newest Horizon thaw request's `thawingUntil`, a Unix time, and 0 for a legacy
-- lock, whose 28-day thaw expired long ago and which is withdrawable now - the pages compare this
-- field to the clock, so a block number here would be wrong in a way that looks right.
-- ---------------------------------------------------------------------------------------------
-- ---------------------------------------------------------------------------------------------
-- The delegation pool per indexer: shares outstanding and tokens in it. Two columns, and they are
-- the only two `lodestar_delegator_stakes` wanted from `lodestar_indexers` - a view that folds the
-- whole ledger and returns forty. Measured on the production nest (2026-09-06): the full join costs
-- 4.20 s, these two columns cost 2.31 s, and `lodestar_delegator_stakes` was over the per-permit
-- DuckDB budget (244 MiB) computing the other thirty-eight to throw them away.
--
-- **The formula is the one `lodestar_indexers` uses, and it has to stay that way.** Both surfaces
-- report a pool; if they drift, an indexer page and a delegator page disagree about the same number.
-- `checks/pool-agrees.sql` fails if they ever differ - that check is the reason this duplication is
-- allowed to exist rather than a second source of truth.
-- ---------------------------------------------------------------------------------------------
CREATE VIEW lodestar_indexer_pool AS
WITH delegation AS (
  SELECT sp, SUM(tok) AS delegated_net, SUM(sh) AS delegator_shares FROM (
    SELECT LOWER(indexer) AS sp,             CAST(tokens AS HUGEINT) AS tok,  CAST(shares AS HUGEINT) AS sh FROM staking_legacy__stake_delegated
    UNION ALL SELECT LOWER(indexer),        -CAST(tokens AS HUGEINT),        -CAST(shares AS HUGEINT)      FROM staking_legacy__stake_delegated_locked
    UNION ALL SELECT LOWER("serviceProvider"),  CAST(tokens AS HUGEINT),      CAST(shares AS HUGEINT)      FROM staking__tokens_delegated
    UNION ALL SELECT LOWER("serviceProvider"), -CAST(tokens AS HUGEINT),     -CAST(shares AS HUGEINT)      FROM staking__tokens_undelegated
  ) GROUP BY 1
),
ledger AS (
  SELECT indexer AS sp, SUM(pool_delta) FILTER (WHERE kind NOT IN ('delegated', 'undelegated')) AS pool_rewards_added
  FROM lodestar_indexer_ledger GROUP BY 1
),
thawing AS (
  SELECT sp, GREATEST(SUM(t), 0) AS delegated_thawing_tokens FROM (
    SELECT LOWER("serviceProvider") AS sp,  CAST(tokens AS HUGEINT) AS t FROM staking__tokens_undelegated
    UNION ALL SELECT LOWER("serviceProvider"), -CAST(tokens AS HUGEINT)  FROM staking__delegated_tokens_withdrawn
    UNION ALL SELECT LOWER(indexer), 0                                    FROM staking_legacy__stake_delegated_locked
  ) GROUP BY 1
)
SELECT d.sp                                                                                   AS id,
       d.delegator_shares,
       COALESCE(d.delegated_net, 0) + COALESCE(l.pool_rewards_added, 0)
         + COALESCE(th.delegated_thawing_tokens, 0)                                           AS delegated_tokens
FROM delegation d
LEFT JOIN ledger  l  ON l.sp  = d.sp
LEFT JOIN thawing th ON th.sp = d.sp;

CREATE VIEW lodestar_delegator_positions AS
WITH events AS (
  SELECT LOWER(delegator) AS delegator, LOWER(indexer) AS indexer, 'in' AS kind, CAST(tokens AS HUGEINT) AS tok, CAST(shares AS HUGEINT) AS sh, CAST(block_timestamp AS BIGINT) AS ts, block_number * 100000 + log_index AS k FROM staking_legacy__stake_delegated
  UNION ALL SELECT LOWER(delegator), LOWER(indexer),            'out', CAST(tokens AS HUGEINT), CAST(shares AS HUGEINT), CAST(block_timestamp AS BIGINT), block_number * 100000 + log_index FROM staking_legacy__stake_delegated_locked
  UNION ALL SELECT LOWER(delegator), LOWER("serviceProvider"),  'in',  CAST(tokens AS HUGEINT), CAST(shares AS HUGEINT), CAST(block_timestamp AS BIGINT), block_number * 100000 + log_index FROM staking__tokens_delegated
  UNION ALL SELECT LOWER(delegator), LOWER("serviceProvider"),  'out', CAST(tokens AS HUGEINT), CAST(shares AS HUGEINT), CAST(block_timestamp AS BIGINT), block_number * 100000 + log_index FROM staking__tokens_undelegated
),
exact AS (
  SELECT delegator, indexer,
         SUM(CASE WHEN kind = 'in' THEN sh ELSE -sh END)      AS share_amount,
         SUM(CASE WHEN kind = 'in' THEN tok ELSE 0 END)       AS total_delegated_tokens,
         SUM(CASE WHEN kind = 'out' THEN tok ELSE 0 END)      AS total_undelegated_tokens,
         MIN(ts)                                              AS created_at,
         MAX(CASE WHEN kind = 'out' THEN ts END)              AS last_undelegated_at
  FROM events GROUP BY 1, 2
),
folded AS (
  SELECT delegator, indexer,
         list_reduce(
           list_prepend(
             {'kind': 'init', 't': 0.0::DOUBLE, 'sh': 0.0::DOUBLE, 'shares': 0.0::DOUBLE, 'rate': 0.0::DOUBLE, 'realized': 0.0::DOUBLE},
             list({'kind': kind, 't': CAST(tok AS DOUBLE), 'sh': CAST(sh AS DOUBLE), 'shares': 0.0::DOUBLE, 'rate': 0.0::DOUBLE, 'realized': 0.0::DOUBLE} ORDER BY k)
           ),
           lambda acc, e:
             CASE WHEN e.kind = 'in' THEN
               {'kind': 's', 't': 0.0::DOUBLE, 'sh': 0.0::DOUBLE,
                'shares': acc.shares + e.sh,
                'rate': CASE WHEN acc.shares + e.sh > 0 THEN (acc.rate * acc.shares + e.t) / (acc.shares + e.sh) ELSE acc.rate END,
                'realized': acc.realized}
             ELSE
               {'kind': 's', 't': 0.0::DOUBLE, 'sh': 0.0::DOUBLE,
                'shares': acc.shares - e.sh,
                'rate': acc.rate,
                'realized': acc.realized + (e.t - e.sh * acc.rate)}
             END
         ) AS st
  FROM events GROUP BY 1, 2
),
withdrawn AS (
  SELECT delegator, indexer, SUM(t) AS t FROM (
    SELECT LOWER(delegator) AS delegator, LOWER(indexer) AS indexer, CAST(tokens AS HUGEINT) AS t FROM staking__stake_delegated_withdrawn
    UNION ALL SELECT LOWER(delegator), LOWER("serviceProvider"), CAST(tokens AS HUGEINT) FROM staking__delegated_tokens_withdrawn
  ) GROUP BY 1, 2
),
-- Horizon thaw requests by a delegator on an indexer: request types 1 and 2 are delegation thaws
-- (`IHorizonStakingTypes.ThawRequestType`: Provision = 0, Delegation = 1, DelegationWithBeneficiary = 2).
thaw AS (
  SELECT LOWER(owner) AS delegator, LOWER("serviceProvider") AS indexer, MAX(CAST("thawingUntil" AS BIGINT)) AS thawing_until
  FROM staking__thaw_request_created WHERE CAST("requestType" AS INTEGER) IN (1, 2) GROUP BY 1, 2
)
SELECT x.delegator || '-' || x.indexer                        AS id,
       x.delegator,
       x.indexer,
       x.share_amount,
       x.total_delegated_tokens,
       x.total_undelegated_tokens,
       f.st.rate                                               AS personal_exchange_rate,
       CAST(f.st.realized AS HUGEINT)                          AS realized_rewards,
       GREATEST(x.total_undelegated_tokens - COALESCE(w.t, 0), 0) AS locked_tokens,
       CASE WHEN x.total_undelegated_tokens - COALESCE(w.t, 0) > 0 THEN COALESCE(t.thawing_until, 0) ELSE 0 END AS locked_until,
       x.share_amount > 0                                      AS active,
       x.created_at,
       x.last_undelegated_at
FROM exact x
JOIN folded f ON f.delegator = x.delegator AND f.indexer = x.indexer
LEFT JOIN withdrawn w ON w.delegator = x.delegator AND w.indexer = x.indexer
LEFT JOIN thaw t ON t.delegator = x.delegator AND t.indexer = x.indexer;

-- ---------------------------------------------------------------------------------------------
-- The positions with the pool attached: `staked_tokens` is what the shares are worth today. Kept
-- apart from `lodestar_delegator_positions` because the join to `lodestar_indexer_pool` cannot be
-- filtered by delegator - DuckDB pushes nothing into the right side of a LEFT JOIN - so every reader
-- of this view pays the whole pool fold (4.8 s on 2026-09-26) even for one delegator. A reader that
-- does not need `staked_tokens`, or that already holds the pool figures, reads the positions view
-- (0.14 s for one delegator) and does the arithmetic below itself.
-- ---------------------------------------------------------------------------------------------
CREATE VIEW lodestar_delegator_stakes AS
SELECT p.id,
       p.delegator,
       p.indexer,
       p.share_amount,
       -- shares * pool_tokens / pool_shares, the contract's uint256 formula. Two wei-scale HUGEINTs
       -- multiplied overflow INT128 (a 15,572 GRT position in a 1.04M GRT pool did, on real data), so
       -- the whole-share part stays exact and only the fractional remainder goes through DOUBLE,
       -- which is within one part in 1e16 of the contract's answer.
       CASE WHEN i.delegator_shares > 0
            THEN (p.share_amount // i.delegator_shares) * i.delegated_tokens
                 + CAST(CAST(p.share_amount % i.delegator_shares AS DOUBLE) * CAST(i.delegated_tokens AS DOUBLE) / CAST(i.delegator_shares AS DOUBLE) AS HUGEINT)
            ELSE 0 END                                         AS staked_tokens,
       p.total_delegated_tokens,
       p.total_undelegated_tokens,
       p.personal_exchange_rate,
       p.realized_rewards,
       p.locked_tokens,
       p.locked_until,
       p.active,
       p.created_at,
       p.last_undelegated_at
FROM lodestar_delegator_positions p
LEFT JOIN lodestar_indexer_pool i ON i.id = p.indexer;

-- ---------------------------------------------------------------------------------------------
-- Per delegator: the subgraph's `Delegator` totals, folded from the positions above so the two
-- surfaces cannot disagree. `stakes_count` counts positions ever opened; `active_stakes_count`
-- those with shares left, the subgraph's rule. Over the positions, not the stakes: none of these
-- totals needs the pool, and the pool join would cost every delegator lookup the whole fold.
-- ---------------------------------------------------------------------------------------------
CREATE VIEW lodestar_delegators AS
SELECT delegator                                  AS id,
       SUM(total_delegated_tokens)                AS total_staked_tokens,
       SUM(total_undelegated_tokens)              AS total_unstaked_tokens,
       SUM(realized_rewards)                      AS total_realized_rewards,
       COUNT(*)                                   AS stakes_count,
       COUNT(*) FILTER (WHERE active)             AS active_stakes_count
FROM lodestar_delegator_positions GROUP BY 1;

-- ---------------------------------------------------------------------------------------------
-- Per (curator, deployment): the subgraph's `Signal`, for the curator portfolio. Curation-level
-- positions only; name signal through GNS is the GNS contract's position here and the curator's
-- `NameSignal` in the subgraph, which no Lodestar page reads. Tokens in are net of the curation
-- tax as the subgraph's `signalledTokens` is; `realized_rewards` is the subgraph's unimplemented 0
-- (no curation handler writes it). The deployment figures beside it follow `lodestar_allocations`'
-- `signal` CTE and the active-allocation sum, so the three surfaces agree.
-- ---------------------------------------------------------------------------------------------
CREATE VIEW lodestar_curator_signals AS
WITH pos AS (
  SELECT curator, dep, SUM(sig) AS signal, SUM(tin) AS signalled_tokens, SUM(tout) AS unsignalled_tokens, MAX(ts) AS last_signal_change FROM (
    SELECT LOWER(curator) AS curator, "subgraphDeploymentID" AS dep,  CAST(signal AS HUGEINT) AS sig, CAST(tokens AS HUGEINT) - CAST("curationTax" AS HUGEINT) AS tin, CAST(0 AS HUGEINT) AS tout, CAST(block_timestamp AS BIGINT) AS ts FROM curation__signalled
    UNION ALL SELECT LOWER(curator), "subgraphDeploymentID", -CAST(signal AS HUGEINT), 0, CAST(tokens AS HUGEINT), CAST(block_timestamp AS BIGINT) FROM curation__burned
  ) GROUP BY 1, 2
),
dep_signal AS (
  SELECT dep, SUM(tok) AS signalled_tokens FROM (
    SELECT "subgraphDeploymentID" AS dep,  CAST(tokens AS HUGEINT) - CAST("curationTax" AS HUGEINT) AS tok FROM curation__signalled
    UNION ALL SELECT "subgraphDeploymentID", -CAST(tokens AS HUGEINT) FROM curation__burned
    UNION ALL SELECT "subgraphDeploymentID",  CAST(tokens AS HUGEINT) FROM curation__collected
  ) GROUP BY 1
),
-- indexers' net query fees on the deployment, the subgraph's `queryFeesAmount` (see lodestar_deployments)
dep_fees AS (SELECT dep, SUM(t) AS query_fees_amount FROM (
  SELECT "subgraphDeploymentId" AS dep, CAST("tokensCollected" AS HUGEINT) - CAST("tokensCurators" AS HUGEINT) - (CAST("tokensCollected" AS HUGEINT) // 100) AS t FROM subgraph_service__query_fees_collected
  UNION ALL SELECT "subgraphDeploymentID", CAST("queryFees" AS HUGEINT) FROM staking_legacy__rebate_collected
  UNION ALL SELECT "subgraphDeploymentID", CAST("rebateFees" AS HUGEINT) FROM staking_legacy__allocation_collected
) GROUP BY 1),
dep_stake AS (SELECT subgraph_deployment AS dep, SUM(allocated_tokens) AS staked_tokens FROM lodestar_allocations WHERE status = 'Active' GROUP BY 1)
SELECT p.curator || '-' || CAST(p.dep AS VARCHAR)   AS id,
       p.curator,
       p.dep                                        AS subgraph_deployment,
       p.signalled_tokens,
       p.unsignalled_tokens,
       p.signal,
       p.last_signal_change,
       CAST(0 AS HUGEINT)                           AS realized_rewards,
       COALESCE(ds.signalled_tokens, 0)             AS deployment_signalled_tokens,
       COALESCE(df.query_fees_amount, 0)            AS deployment_query_fees_amount,
       COALESCE(dst.staked_tokens, 0)               AS deployment_staked_tokens
FROM pos p
LEFT JOIN dep_signal ds ON ds.dep = p.dep
LEFT JOIN dep_fees df ON df.dep = p.dep
LEFT JOIN dep_stake dst ON dst.dep = p.dep;

-- ---------------------------------------------------------------------------------------------
-- Curators, per the network subgraph's own rule (network view, #649): a curator is an address that
-- ever signalled through Curation *or* GNS, positions are netted per (curator, deployment) and per
-- (curator, subgraph) separately, and "active" is holding at least one position with signal left.
-- On L2 most signal is routed through GNS and the Curation-level curator is then the GNS contract
-- itself; that row is kept and flagged `is_gns`, so `api/curators` can drop it the way the subgraph's
-- list effectively does, without this view deciding for it.
-- ---------------------------------------------------------------------------------------------
CREATE VIEW lodestar_curators AS
WITH positions AS (
  SELECT curator, position, SUM(sig) AS net_signal, SUM(tin) AS tokens_in, SUM(tout) AS tokens_out FROM (
    -- `totalSignalledTokens` is net of the curation tax in the subgraph (`tokens.minus(curationTax)`,
    -- curation.ts handleSignalled); the GNS deposit is what was deposited.
    SELECT LOWER(curator) AS curator, 'v:' || CAST("subgraphDeploymentID" AS VARCHAR) AS position,  CAST(signal AS HUGEINT) AS sig, CAST(tokens AS HUGEINT) - CAST("curationTax" AS HUGEINT) AS tin, CAST(0 AS HUGEINT) AS tout FROM curation__signalled
    UNION ALL SELECT LOWER(curator), 'v:' || CAST("subgraphDeploymentID" AS VARCHAR), -CAST(signal AS HUGEINT), 0, CAST(tokens AS HUGEINT) FROM curation__burned
    UNION ALL SELECT LOWER(curator), 'n:' || CAST("subgraphID" AS VARCHAR),  CAST("nSignalCreated" AS HUGEINT), CAST("tokensDeposited" AS HUGEINT), 0 FROM gns__signal_minted
    UNION ALL SELECT LOWER(curator), 'n:' || CAST("subgraphID" AS VARCHAR), -CAST("nSignalBurnt" AS HUGEINT), 0, CAST("tokensReceived" AS HUGEINT) FROM gns__signal_burned
  ) GROUP BY 1, 2
)
SELECT curator                                            AS id,
       SUM(tokens_in)                                     AS total_signalled_tokens,
       SUM(tokens_out)                                    AS total_unsignalled_tokens,
       -- `signalCount` / `activeSignalCount` count Curation-level positions only; GNS (name signal)
       -- positions are the subgraph's `nameSignalCount` and are reported separately. Counting both under
       -- one name read 665 against 17 for one curator on the gateway.
       COUNT(*) FILTER (WHERE position LIKE 'v:%')                          AS signal_count,
       COUNT(*) FILTER (WHERE position LIKE 'v:%' AND net_signal > 0)       AS active_signal_count,
       COUNT(*) FILTER (WHERE position LIKE 'n:%')                          AS name_signal_count,
       COUNT(*) FILTER (WHERE position LIKE 'n:%' AND net_signal > 0)       AS active_name_signal_count,
       -- The subgraph's `Curator.realizedRewards` is marked "NOT IMPLEMENTED" in its own schema and no
       -- curation or GNS handler writes it, so it has been 0 on the gateway path since the field was
       -- added. Zero here is the same fact, stated rather than reproduced by accident.
       CAST(0 AS HUGEINT)                                 AS realized_rewards,
       curator = '0xec9a7fb6cbc2e41926127929c2dce6e9c5d33bec' AS is_gns
FROM positions GROUP BY 1;

-- ---------------------------------------------------------------------------------------------
-- Provisions, per (indexer, verifier): the subgraph's `Provision`. Created plus increased, less
-- deprovisioned and slashed; thawing is what has been thawed and not yet deprovisioned. Allocation
-- and reward figures only mean anything for the subgraph service's provision, and are joined for
-- that verifier only (the address is the nest's `subgraph_service` contract).
-- ---------------------------------------------------------------------------------------------
CREATE VIEW lodestar_provisions AS
WITH created AS (
  SELECT LOWER("serviceProvider") AS indexer, LOWER(verifier) AS verifier,
         CAST("maxVerifierCut" AS HUGEINT) AS max_verifier_cut,
         CAST("thawingPeriod" AS HUGEINT)  AS thawing_period,
         block_timestamp AS created_at, block_number AS created_at_block,
         ROW_NUMBER() OVER (PARTITION BY LOWER("serviceProvider"), LOWER(verifier) ORDER BY block_number DESC, log_index DESC) AS rn
  FROM staking__provision_created
),
flows AS (
  SELECT indexer, verifier, SUM(t) AS tokens_provisioned, GREATEST(SUM(th), 0) AS tokens_thawing FROM (
    SELECT LOWER("serviceProvider") AS indexer, LOWER(verifier) AS verifier,  CAST(tokens AS HUGEINT) AS t, CAST(0 AS HUGEINT) AS th FROM staking__provision_created
    UNION ALL SELECT LOWER("serviceProvider"), LOWER(verifier),  CAST(tokens AS HUGEINT), 0 FROM staking__provision_increased
    UNION ALL SELECT LOWER("serviceProvider"), LOWER(verifier), -CAST(tokens AS HUGEINT), -CAST(tokens AS HUGEINT) FROM staking__tokens_deprovisioned
    UNION ALL SELECT LOWER("serviceProvider"), LOWER(verifier), -CAST(tokens AS HUGEINT), 0 FROM staking__provision_slashed
    UNION ALL SELECT LOWER("serviceProvider"), LOWER(verifier), 0,  CAST(tokens AS HUGEINT) FROM staking__provision_thawed
  ) GROUP BY 1, 2
),
service_allocs AS (
  SELECT LOWER(indexer) AS indexer,
         SUM(allocated_tokens) FILTER (WHERE status = 'Active') AS tokens_allocated,
         COUNT(*) FILTER (WHERE status = 'Active')             AS allocation_count,
         SUM(indexing_rewards)                                  AS rewards_earned,
         SUM(query_fees_collected)                              AS query_fees_collected
  FROM lodestar_allocations GROUP BY 1
)
SELECT f.indexer || '-' || f.verifier                 AS id,
       f.indexer,
       f.verifier                                     AS data_service,
       f.tokens_provisioned,
       f.tokens_thawing,
       c.max_verifier_cut,
       c.thawing_period,
       c.created_at,
       c.created_at_block,
       CASE WHEN f.verifier = '0xb2bb92d0de618878e438b55d5846cfecd9301105' THEN COALESCE(sa.tokens_allocated, 0) END      AS tokens_allocated,
       CASE WHEN f.verifier = '0xb2bb92d0de618878e438b55d5846cfecd9301105' THEN COALESCE(sa.allocation_count, 0) END      AS allocation_count,
       CASE WHEN f.verifier = '0xb2bb92d0de618878e438b55d5846cfecd9301105' THEN COALESCE(sa.rewards_earned, 0) END        AS rewards_earned,
       CASE WHEN f.verifier = '0xb2bb92d0de618878e438b55d5846cfecd9301105' THEN COALESCE(sa.query_fees_collected, 0) END  AS query_fees_collected
FROM flows f
LEFT JOIN (SELECT * FROM created WHERE rn = 1) c ON c.indexer = f.indexer AND c.verifier = f.verifier
LEFT JOIN service_allocs sa ON sa.indexer = f.indexer;

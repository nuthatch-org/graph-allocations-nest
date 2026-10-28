-- Lodestar's `SubgraphEpoch` shape (RFC-0011), served from events.
--
-- **The trap this view exists to avoid.** Inside an Arbitrum contract `block.number` is the **L1**
-- block, so EpochManager counts epochs in L1 blocks while a log's `block_number` is **L2**. Computing
-- epochs in L2 block space is wrong by a factor of ~48 (60,142 epochs where the network has 1,356).
--
-- So every block this nest holds is placed by its own `l1_block_number` (`[extract] l1_blocks`),
-- with EpochManager's arithmetic: within a length segment that began at L1 block `anchor` in epoch
-- `e0` with length `len`, `epoch(l1) = e0 + (l1 - anchor) // len`. The segments are the
-- `EpochLengthUpdate` events. The first (initialize) sets `anchor` to its own L1 block; each later one
-- re-anchors at `currentEpochBlock()`, the start of the epoch it fired in, which is the previous
-- anchor plus whole epochs of the previous length. On Arbitrum One that gives epoch 1 at L1
-- 16,083,151 with length 6,646, then epoch 92 at L1 16,687,937 with length 7,200, which are the
-- contract's `lastLengthUpdateEpoch()`, `lastLengthUpdateBlock()` and `epochLength()` at the tip.
--
-- An epoch's `start_block` is the first L2 block this nest holds in it, not the chain's first L2
-- block of the epoch: only log-bearing blocks carry an L1 number here. Bucketing by it is still
-- exact, because L1 numbers never decrease along L2, so every row of the nest falls in the epoch its
-- own block's L1 number says. `start_l1_block` and `end_l1_block` are the epoch's exact L1 range,
-- the numbers the network subgraph reports as `startBlock` and `endBlock`. See
-- nightswatchhq/nuthatch#1116 and #1882.
CREATE VIEW epoch_boundaries AS
WITH length_updates AS (
  SELECT CAST(u.epoch AS HUGEINT) AS e0, CAST(u."epochLength" AS HUGEINT) AS len,
         CAST(l.l1_block_number AS HUGEINT) AS l1, u.block_number * 100000 + u.log_index AS k
  FROM epochs__epoch_length_update u
  JOIN l1_blocks l ON l.block_number = u.block_number AND l.block_hash = u.block_hash
),
steps AS (
  SELECT e0, len, l1, k, (LEAD(e0) OVER (ORDER BY k) - e0) * len AS step FROM length_updates
),
segments AS (
  SELECT e0, len, k,
         MIN(l1) OVER () + COALESCE(SUM(step) OVER (ORDER BY k ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS anchor
  FROM steps
),
-- Two updates inside one epoch share an anchor, and the later one is in force: an empty range.
ranges AS (
  SELECT e0, len, anchor, LEAD(anchor) OVER (ORDER BY k) AS next_anchor FROM segments
),
per_epoch AS (
  SELECT r.e0 + (b.l1 - r.anchor) // r.len AS epoch,
         r.anchor + (b.l1 - r.anchor) // r.len * r.len AS start_l1_block,
         r.len,
         MIN(b.block_number) AS first_seen, MAX(b.block_number) AS last_seen
  FROM (SELECT block_number, CAST(l1_block_number AS HUGEINT) AS l1 FROM l1_blocks) b
  JOIN ranges r ON b.l1 >= r.anchor AND (r.next_anchor IS NULL OR b.l1 < r.next_anchor)
  GROUP BY 1, 2, 3
)
SELECT p.epoch,
       CAST(p.first_seen AS BIGINT) AS start_block,
       -- An epoch ends where the next one starts. The newest has no successor yet, so it runs to its
       -- own last observation - open-ended rather than wrong.
       CAST(COALESCE(LEAD(p.first_seen) OVER (ORDER BY p.epoch) - 1, p.last_seen) AS BIGINT) AS end_block,
       -- for bucketing: the newest epoch takes everything after it too, or the current epoch's fees
       -- and signal read 0 until the next `EpochRun` (nuthatch#1160)
       CAST(COALESCE(LEAD(p.first_seen) OVER (ORDER BY p.epoch) - 1, 9223372036854775807) AS BIGINT) AS until_block,
       CAST(p.last_seen AS BIGINT) AS last_seen,
       -- The L2 blocks between the predecessor's last row and this epoch's first, where the chain's
       -- own first block of the epoch lies. No row of this nest is in them, so nothing is misfiled.
       CAST(COALESCE(p.first_seen - LAG(p.last_seen) OVER (ORDER BY p.epoch) - 1, 0) AS BIGINT) AS unobserved_gap_blocks,
       CAST(p.start_l1_block AS BIGINT) AS start_l1_block,
       -- A length change takes effect from the start of the epoch it fired in, so an epoch's own
       -- segment length is its length, and this is the start of the next epoch less one.
       CAST(p.start_l1_block + p.len - 1 AS BIGINT) AS end_l1_block,
       'l1' AS boundary_source
FROM per_epoch p;

-- The per-epoch totals Lodestar wants. Rewards carry their own epoch; query fees do not, so they are
-- bucketed by block against the boundaries above.
CREATE VIEW lodestar_epochs AS
-- Legacy `RewardsAssigned` carries the epoch and the whole amount; the delegators' share is the pool's
-- cut in force at that block (contract rounding, `amount - amount * cut // 1e6`), and nothing when
-- the pool had no shares - the same model `lodestar_indexer_ledger` measured exact against the
-- contracts. Horizon's `IndexingRewardsCollected` states the split itself.
WITH legacy_cuts AS (
  SELECT LOWER(indexer) AS sp, CAST("indexingRewardCut" AS HUGEINT) AS cut, block_number * 100000 + log_index AS k FROM staking_legacy__delegation_parameters_updated
),
legacy_shares AS (
  SELECT sp, k, SUM(sh) OVER (PARTITION BY sp ORDER BY k ROWS UNBOUNDED PRECEDING) AS cum_shares FROM (
    SELECT LOWER(indexer) AS sp, block_number * 100000 + log_index AS k,  CAST(shares AS HUGEINT) AS sh FROM staking_legacy__stake_delegated
    UNION ALL SELECT LOWER(indexer), block_number * 100000 + log_index, -CAST(shares AS HUGEINT) FROM staking_legacy__stake_delegated_locked
    UNION ALL SELECT LOWER("serviceProvider"), block_number * 100000 + log_index,  CAST(shares AS HUGEINT) FROM staking__tokens_delegated
    UNION ALL SELECT LOWER("serviceProvider"), block_number * 100000 + log_index, -CAST(shares AS HUGEINT) FROM staking__tokens_undelegated
  )
),
legacy_rewards AS (
  -- Each reward with the delegation parameters and pool shares in force at it: the newest
  -- `legacy_cuts` and `legacy_shares` rows at or before its key. That is an `ASOF LEFT JOIN`, which
  -- only DuckDB spells; here the newest key of each is carried forward over the three streams in key
  -- order (a change at the same key as a reward sorts first and applies, as `>=` did), and the reward
  -- then joins each on that exact key. `k` is unique per event, so the join adds no rows.
  SELECT r.epoch, r.amount,
         CASE WHEN c.cut IS NOT NULL AND COALESCE(ps.cum_shares, 0) > 0 THEN r.amount - r.amount * c.cut // 1000000 ELSE 0 END AS delegator_share
  FROM (
    SELECT sp, epoch, amount, ck, pk FROM (
      SELECT sp, epoch, amount, src,
             MAX(CASE WHEN src = 0 THEN k END) OVER (PARTITION BY sp ORDER BY k, src ROWS UNBOUNDED PRECEDING) AS ck,
             MAX(CASE WHEN src = 1 THEN k END) OVER (PARTITION BY sp ORDER BY k, src ROWS UNBOUNDED PRECEDING) AS pk
      FROM (
        SELECT sp, k, 0 AS src, CAST(NULL AS HUGEINT) AS epoch, CAST(NULL AS HUGEINT) AS amount FROM legacy_cuts
        UNION ALL SELECT sp, k, 1, NULL, NULL FROM legacy_shares
        UNION ALL SELECT LOWER(indexer), block_number * 100000 + log_index, 2, CAST(epoch AS HUGEINT), CAST(amount AS HUGEINT) FROM rewards__rewards_assigned
      )
    ) WHERE src = 2
  ) r
  LEFT JOIN legacy_cuts c ON c.sp = r.sp AND c.k = r.ck
  LEFT JOIN legacy_shares ps ON ps.sp = r.sp AND ps.k = r.pk
),
rewards AS (
  SELECT epoch, SUM(total) AS total_rewards, SUM(indexer) AS total_indexer_rewards, SUM(delegator) AS total_delegator_rewards FROM (
    SELECT CAST("currentEpoch" AS HUGEINT) AS epoch, CAST("tokensRewards" AS HUGEINT) AS total,
           CAST("tokensIndexerRewards" AS HUGEINT) AS indexer, CAST("tokensDelegationRewards" AS HUGEINT) AS delegator
    FROM subgraph_service__indexing_rewards_collected
    UNION ALL SELECT epoch, amount, amount - delegator_share, delegator_share FROM legacy_rewards
  ) GROUP BY 1
),
-- `queryFeesCollected` in the network subgraph is **net**, not gross: the curator share and a 1%
-- protocol tax are both taken out, and the tax is truncated **per event** rather than on the epoch
-- total. Summing first and taxing the total is wrong by a few hundred wei per epoch, which is small
-- enough to look like rounding noise and is in fact a different quantity. Integer division is
-- required: DuckDB's `/` returns a DOUBLE and loses precision outright at 1e23.
-- Measured over the 175 closed epochs from 1195 up, this took exact agreement from 0 to 145.
-- Both eras: legacy `RebateCollected.queryFees` is already the indexer's net and `curationFees` the
-- curators'; the pre-rebate `AllocationCollected` gives the same net as `rebateFees` (its `tokens` also
-- carries the protocol tax, which read 114 early epochs about 1% high).
fees AS (
  SELECT b.epoch, SUM(q.net) AS query_fees_collected, SUM(q.curators) AS curator_query_fees
  FROM (
    SELECT block_number, CAST("tokensCollected" AS HUGEINT) - CAST("tokensCurators" AS HUGEINT) - (CAST("tokensCollected" AS HUGEINT) // 100) AS net, CAST("tokensCurators" AS HUGEINT) AS curators FROM subgraph_service__query_fees_collected
    UNION ALL SELECT block_number, CAST("queryFees" AS HUGEINT), CAST("curationFees" AS HUGEINT) FROM staking_legacy__rebate_collected
    UNION ALL SELECT block_number, CAST("rebateFees" AS HUGEINT), CAST("curationFees" AS HUGEINT) FROM staking_legacy__allocation_collected
  ) q
  JOIN epoch_boundaries b
    ON q.block_number >= b.start_block AND q.block_number <= b.until_block
  GROUP BY 1
),
-- `signalledTokens` is **gross signal net of the curation tax**, and burns are not subtracted from
-- it at all. This previously computed `signalled - burned` and ignored `curationTax`, wrong in two
-- directions at once. The tell was that 81 of 266 epochs came out **negative**: a net flow was being
-- compared against something that is not a flow, and a negative token quantity is impossible as the
-- stock the subgraph is reporting. Measured, exact agreement went from 6 of 175 to 165 of 175, and
-- the ten that remain are five adjacent pairs of equal and opposite magnitude - value filed one
-- epoch out by the observed boundaries this view had before `l1_blocks` (#1116), not value lost.
signal AS (
  SELECT b.epoch,
         SUM(CAST(s.tokens AS HUGEINT) - CAST(s."curationTax" AS HUGEINT)) AS signalled_tokens
  FROM curation__signalled s
  JOIN epoch_boundaries b ON s.block_number >= b.start_block AND s.block_number <= b.until_block
  GROUP BY 1
),
-- The subgraph's `Epoch.stakeDeposited`: own stake deposited during the epoch, both eras' events
-- (nuthatch#1160, for `api/epochs`). And the protocol's cut of the epoch's query fees, the
-- `tokensCollected // 100` the `fees` CTE already subtracts, exposed for `api/token-metrics`'
-- `taxedQueryFees`.
deposits AS (
  SELECT b.epoch, SUM(t) AS stake_deposited FROM (
    SELECT block_number, CAST(tokens AS HUGEINT) AS t FROM staking_legacy__stake_deposited
    UNION ALL SELECT block_number, CAST(tokens AS HUGEINT) FROM staking__horizon_stake_deposited
  ) d JOIN epoch_boundaries b ON d.block_number >= b.start_block AND d.block_number <= b.until_block
  GROUP BY 1
),
protocol_tax AS (
  SELECT b.epoch, SUM(q.tax) AS taxed_query_fees
  FROM (
    SELECT block_number, CAST("tokensCollected" AS HUGEINT) // 100 AS tax FROM subgraph_service__query_fees_collected
    UNION ALL SELECT block_number, CAST("protocolTax" AS HUGEINT) FROM staking_legacy__rebate_collected
  ) q
  JOIN epoch_boundaries b ON q.block_number >= b.start_block AND q.block_number <= b.until_block
  GROUP BY 1
)
SELECT b.epoch                                  AS id,
       b.start_block,
       b.end_block,
       b.start_l1_block,
       b.end_l1_block,
       COALESCE(s.signalled_tokens, 0)          AS signalled_tokens,
       COALESCE(d.stake_deposited, 0)           AS stake_deposited,
       COALESCE(p.taxed_query_fees, 0)          AS taxed_query_fees,
       COALESCE(r.total_rewards, 0)             AS total_rewards,
       COALESCE(r.total_indexer_rewards, 0)     AS total_indexer_rewards,
       COALESCE(r.total_delegator_rewards, 0)   AS total_delegator_rewards,
       COALESCE(f.query_fees_collected, 0)      AS query_fees_collected,
       COALESCE(f.curator_query_fees, 0)        AS curator_query_fees
FROM epoch_boundaries b
LEFT JOIN rewards r ON r.epoch = b.epoch
LEFT JOIN fees    f ON f.epoch = b.epoch
LEFT JOIN signal  s ON s.epoch = b.epoch
LEFT JOIN deposits d ON d.epoch = b.epoch
LEFT JOIN protocol_tax p ON p.epoch = b.epoch
ORDER BY b.epoch;

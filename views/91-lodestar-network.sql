-- Lodestar's `graphNetwork` singleton (RFC-0011), assembled from events instead of the gateway.
--
-- This is the one module in the migration that is genuinely an *aggregate* rather than a table, which
-- is why it was ranked last. Fourteen protocol-wide numbers, each a fold over a different contract's
-- events, and one that is not derivable at all without indexing millions of token transfers - so that
-- one is a pinned `eth_call` instead (RFC-0023 tier 3, `total_supply` and `issuance_per_block`).
CREATE VIEW lodestar_network AS
WITH staked AS (
  -- Netted **per entity** before counting. Counting rows with `t > 0` instead answers "who ever
  -- had an inflow", which is the same set as "who ever appears" - that is why this used to return
  -- n_positive == n_all exactly, a number that agreed with itself and with nothing else.
  SELECT SUM(net) AS total, COUNT(*) AS n_all,
         COUNT(*) FILTER (WHERE net > 0) AS n_positive
  FROM (
    SELECT sp, SUM(t) AS net FROM (
    -- Legacy era. Horizon renamed these wholesale at block ~408,847,369, so both halves are needed
    -- and neither alone is the protocol's history: the Horizon table starts 366M blocks in.
    SELECT indexer AS sp,             CAST(tokens AS HUGEINT) AS t FROM staking_legacy__stake_deposited
    UNION ALL
    SELECT indexer,                  -CAST(tokens AS HUGEINT)      FROM staking_legacy__stake_withdrawn
    UNION ALL
    SELECT "serviceProvider",         CAST(tokens AS HUGEINT)      FROM staking__horizon_stake_deposited
    UNION ALL
    SELECT "serviceProvider",        -CAST(tokens AS HUGEINT)      FROM staking__horizon_stake_withdrawn
    UNION ALL
    -- Slashing, and it is the whole of #649 gap 3. Deposits minus withdrawals left three indexers
    -- holding 97k-247k GRT that the subgraph reports at zero; each had been slashed for *exactly*
    -- its remaining balance, to the decimal. `tokens` is the full amount removed - the `reward`
    -- beside it is the informer's cut of that same sum, not an additional debit, so subtracting
    -- both would double-count.
    --
    -- Legacy only. `ProvisionSlashed` exists on the Horizon ABI and has never fired: 0 logs across
    -- 408,000,000..496,956,109, checked against a control on the same address and range returning
    -- 129,387. The legacy signature had to be confirmed the same way - the first attempt guessed a
    -- five-parameter form, got 0 logs, and that zero looked exactly like an answer.
    SELECT indexer,                  -CAST(tokens AS HUGEINT)      FROM staking_legacy__stake_slashed
    ) GROUP BY 1
  )
),
-- Delegation, across both eras, and the two eras leave the pool at different moments.
--
-- Legacy: undelegating emits `StakeDelegatedLocked`, which burns the shares and moves the tokens out
-- of the pool immediately into a thawing lock; `StakeDelegatedWithdrawn` merely releases what already
-- left. So the legacy subtraction is at *lock*, and subtracting the withdrawal instead would
-- double-count nothing but would lag the pool by the thawing period.
--
-- Horizon: `DelegatedTokensWithdrawn` is the exit. Whether the Horizon pool should also shrink at
-- `TokensUndelegated` is the one modelling choice here that the gateway comparison arbitrates rather
-- than reasoning - stated plainly because it is the likeliest thing to be wrong.
-- Delegation. Two corrections live here, both from reading the subgraph's mappings rather than
-- reasoning about the protocol.
--
-- **The exit event.** A Horizon delegation leaves the pool at `TokensUndelegated`, which burns the
-- shares; `DelegatedTokensWithdrawn` only releases tokens that already left and are done thawing.
-- Subtracting at withdrawal counts a thawing stake as still delegated, which is what left
-- `totalDelegatedTokens` 16.3% high. The legacy era has the same shape with different names:
-- `StakeDelegatedLocked` is the exit, `StakeDelegatedWithdrawn` the release.
--
-- **Shares, not tokens.** `activeDelegatorCount` tracks `delegatedStake.shareAmount` reaching zero
-- (`staking.ts:249`, `horizonStaking.ts:510`), never the token balance. Tokens accrue rewards while
-- shares do not, so the two diverge and netting tokens reports the wrong people as active.
delegation AS (
  SELECT delegator, sp, SUM(tok) AS net_tokens, SUM(sh) AS net_shares FROM (
    SELECT delegator, indexer AS sp,
           CAST(tokens AS HUGEINT) AS tok,  CAST(shares AS HUGEINT) AS sh
      FROM staking_legacy__stake_delegated
    UNION ALL
    SELECT delegator, indexer,
          -CAST(tokens AS HUGEINT),        -CAST(shares AS HUGEINT)
      FROM staking_legacy__stake_delegated_locked
    UNION ALL
    SELECT delegator, "serviceProvider",
           CAST(tokens AS HUGEINT),         CAST(shares AS HUGEINT)
      FROM staking__tokens_delegated
    UNION ALL
    SELECT delegator, "serviceProvider",
          -CAST(tokens AS HUGEINT),        -CAST(shares AS HUGEINT)
      FROM staking__tokens_undelegated
  ) GROUP BY 1, 2
),
delegated AS (
  SELECT (SELECT SUM(net_tokens) FROM delegation) AS total,
         (SELECT COUNT(DISTINCT delegator) FROM delegation) AS n_all,
         (SELECT COUNT(DISTINCT delegator) FROM delegation WHERE net_shares > 0) AS n_positive
),
-- Curators, per the network subgraph's own rule (#649). `curatorCount` is distinct addresses ever
-- passed to `createOrLoadCurator`, which fires from Curation `Signalled`/`Burned` *and* from the GNS
-- name-signal handlers. Counting Curation alone gave 50 against the gateway's 1,819, because on L2
-- most signal is routed through GNS and the Curation-level `curator` is then the GNS contract itself.
--
-- `activeCuratorCount` is a different question and is not a distinct count: the subgraph increments
-- it only when a curator's `activeCombinedSignalCount` reaches 1, so it means "curators holding at
-- least one live position". A position is (curator, deployment) for curation signal and
-- (curator, subgraphID) for name signal, netted separately and only then folded together.
curator_positions AS (
  SELECT curator, position, SUM(sig) AS net FROM (
    SELECT curator, 'v:' || CAST("subgraphDeploymentID" AS VARCHAR) AS position,
           CAST(signal AS HUGEINT) AS sig FROM curation__signalled
    UNION ALL
    SELECT curator, 'v:' || CAST("subgraphDeploymentID" AS VARCHAR),
          -CAST(signal AS HUGEINT)      FROM curation__burned
    UNION ALL
    SELECT curator, 'n:' || CAST("subgraphID" AS VARCHAR),
           CAST("nSignalCreated" AS HUGEINT) FROM gns__signal_minted
    UNION ALL
    SELECT curator, 'n:' || CAST("subgraphID" AS VARCHAR),
          -CAST("nSignalBurnt" AS HUGEINT)   FROM gns__signal_burned
    -- `GRTWithdrawn` is deliberately absent. It is one of the eight handlers that create a Curator
    -- in the subgraph, but it never fired on L2 - the event belongs to the L1 migration path - so
    -- nuthatch created no table for it, and a view referencing a table that does not exist fails to
    -- load *in its entirety*, taking the other thirteen fields with it. See issue #663.
  ) GROUP BY 1, 2
),
signalled AS (
  -- What the curation pools hold, as 40, 90 and 95 already count it per deployment: the tax is
  -- burned on the way in and curators' query-fee share is paid in by `Collected`. Without both this
  -- sat 1.5M GRT under the network subgraph's totalTokensSignalled; with them it agrees to the wei.
  SELECT (SELECT SUM(t) FROM (
            SELECT CAST(tokens AS HUGEINT) - CAST("curationTax" AS HUGEINT) AS t FROM curation__signalled
            UNION ALL SELECT -CAST(tokens AS HUGEINT) FROM curation__burned
            UNION ALL SELECT CAST(tokens AS HUGEINT) FROM curation__collected
          )) AS total,
         (SELECT COUNT(DISTINCT curator) FROM curator_positions) AS n_all,
         (SELECT COUNT(DISTINCT curator) FROM curator_positions WHERE net > 0) AS n_positive
),
allocated AS (
  SELECT SUM(allocated_tokens) AS total FROM lodestar_allocations WHERE status = 'Active'
),
subgraphs AS (
  -- The active count as its own query rather than an aggregate FILTER holding a subquery, which not
  -- every engine plans; the `NOT IN` keeps its meaning (a NULL deprecated id counts none as active).
  SELECT (SELECT COUNT(DISTINCT "subgraphID") FROM gns__subgraph_published) AS n_all,
         (SELECT COUNT(DISTINCT "subgraphID") FROM gns__subgraph_published
          WHERE "subgraphID" NOT IN (SELECT "subgraphID" FROM gns__subgraph_deprecated)) AS n_active
),
-- The newest pinned reads. `reverted` would mean the call failed at that block, which is a fact about
-- chain state rather than a zero, so it is excluded rather than counted as none. `issuance_per_block`
-- reverts on every block before 75,279,040, where the getter did not yet exist, so on a nest that has
-- not reached that height the column is null rather than wrong.
--
-- `result` is the raw 32-byte return word, kept as bytes because a call result has no ABI type on
-- this side. Both of these are `uint256`, so the decode is the last 32 hex characters folded
-- base-16 into a HUGEINT: 128 bits, which holds anything up to 3.4e38 and so cannot overflow on a
-- token whose supply is 3.5e27. The `_raw` column stays as it was, because it is what a caller
-- checks the decode against.
supply AS (
  -- `list_reduce(..., acc * 16 + d)` written out as the sum it computes, so an engine without
  -- DuckDB's list lambdas reads the same number (the same fold as `lodestar_network_params`).
  SELECT raw,
         CAST(strpos('0123456789abcdef', substr(h, 1, 1)) - 1 AS HUGEINT) * CAST('21267647932558653966460912964485513216' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 2, 1)) - 1 AS HUGEINT) * CAST('1329227995784915872903807060280344576' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 3, 1)) - 1 AS HUGEINT) * CAST('83076749736557242056487941267521536' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 4, 1)) - 1 AS HUGEINT) * CAST('5192296858534827628530496329220096' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 5, 1)) - 1 AS HUGEINT) * CAST('324518553658426726783156020576256' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 6, 1)) - 1 AS HUGEINT) * CAST('20282409603651670423947251286016' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 7, 1)) - 1 AS HUGEINT) * CAST('1267650600228229401496703205376' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 8, 1)) - 1 AS HUGEINT) * CAST('79228162514264337593543950336' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 9, 1)) - 1 AS HUGEINT) * CAST('4951760157141521099596496896' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 10, 1)) - 1 AS HUGEINT) * CAST('309485009821345068724781056' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 11, 1)) - 1 AS HUGEINT) * CAST('19342813113834066795298816' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 12, 1)) - 1 AS HUGEINT) * CAST('1208925819614629174706176' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 13, 1)) - 1 AS HUGEINT) * CAST('75557863725914323419136' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 14, 1)) - 1 AS HUGEINT) * CAST('4722366482869645213696' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 15, 1)) - 1 AS HUGEINT) * CAST('295147905179352825856' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 16, 1)) - 1 AS HUGEINT) * CAST('18446744073709551616' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 17, 1)) - 1 AS HUGEINT) * CAST('1152921504606846976' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 18, 1)) - 1 AS HUGEINT) * CAST('72057594037927936' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 19, 1)) - 1 AS HUGEINT) * CAST('4503599627370496' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 20, 1)) - 1 AS HUGEINT) * CAST('281474976710656' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 21, 1)) - 1 AS HUGEINT) * CAST('17592186044416' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 22, 1)) - 1 AS HUGEINT) * CAST('1099511627776' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 23, 1)) - 1 AS HUGEINT) * CAST('68719476736' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 24, 1)) - 1 AS HUGEINT) * CAST('4294967296' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 25, 1)) - 1 AS HUGEINT) * CAST('268435456' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 26, 1)) - 1 AS HUGEINT) * CAST('16777216' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 27, 1)) - 1 AS HUGEINT) * CAST('1048576' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 28, 1)) - 1 AS HUGEINT) * CAST('65536' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 29, 1)) - 1 AS HUGEINT) * CAST('4096' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 30, 1)) - 1 AS HUGEINT) * CAST('256' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 31, 1)) - 1 AS HUGEINT) * CAST('16' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 32, 1)) - 1 AS HUGEINT) * CAST('1' AS HUGEINT) AS value,
         block_number
  FROM (SELECT CAST(result AS VARCHAR) AS raw, right(lower(CAST(result AS VARCHAR)), 32) AS h, block_number
        FROM total_supply WHERE reverted = false
        ORDER BY block_number DESC LIMIT 1)
),
issuance AS (
  SELECT CAST(strpos('0123456789abcdef', substr(h, 1, 1)) - 1 AS HUGEINT) * CAST('21267647932558653966460912964485513216' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 2, 1)) - 1 AS HUGEINT) * CAST('1329227995784915872903807060280344576' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 3, 1)) - 1 AS HUGEINT) * CAST('83076749736557242056487941267521536' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 4, 1)) - 1 AS HUGEINT) * CAST('5192296858534827628530496329220096' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 5, 1)) - 1 AS HUGEINT) * CAST('324518553658426726783156020576256' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 6, 1)) - 1 AS HUGEINT) * CAST('20282409603651670423947251286016' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 7, 1)) - 1 AS HUGEINT) * CAST('1267650600228229401496703205376' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 8, 1)) - 1 AS HUGEINT) * CAST('79228162514264337593543950336' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 9, 1)) - 1 AS HUGEINT) * CAST('4951760157141521099596496896' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 10, 1)) - 1 AS HUGEINT) * CAST('309485009821345068724781056' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 11, 1)) - 1 AS HUGEINT) * CAST('19342813113834066795298816' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 12, 1)) - 1 AS HUGEINT) * CAST('1208925819614629174706176' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 13, 1)) - 1 AS HUGEINT) * CAST('75557863725914323419136' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 14, 1)) - 1 AS HUGEINT) * CAST('4722366482869645213696' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 15, 1)) - 1 AS HUGEINT) * CAST('295147905179352825856' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 16, 1)) - 1 AS HUGEINT) * CAST('18446744073709551616' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 17, 1)) - 1 AS HUGEINT) * CAST('1152921504606846976' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 18, 1)) - 1 AS HUGEINT) * CAST('72057594037927936' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 19, 1)) - 1 AS HUGEINT) * CAST('4503599627370496' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 20, 1)) - 1 AS HUGEINT) * CAST('281474976710656' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 21, 1)) - 1 AS HUGEINT) * CAST('17592186044416' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 22, 1)) - 1 AS HUGEINT) * CAST('1099511627776' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 23, 1)) - 1 AS HUGEINT) * CAST('68719476736' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 24, 1)) - 1 AS HUGEINT) * CAST('4294967296' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 25, 1)) - 1 AS HUGEINT) * CAST('268435456' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 26, 1)) - 1 AS HUGEINT) * CAST('16777216' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 27, 1)) - 1 AS HUGEINT) * CAST('1048576' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 28, 1)) - 1 AS HUGEINT) * CAST('65536' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 29, 1)) - 1 AS HUGEINT) * CAST('4096' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 30, 1)) - 1 AS HUGEINT) * CAST('256' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 31, 1)) - 1 AS HUGEINT) * CAST('16' AS HUGEINT) +
         CAST(strpos('0123456789abcdef', substr(h, 32, 1)) - 1 AS HUGEINT) * CAST('1' AS HUGEINT) AS value,
         block_number
  FROM (SELECT right(lower(CAST(result AS VARCHAR)), 32) AS h, block_number
        FROM issuance_per_block WHERE reverted = false
        ORDER BY block_number DESC LIMIT 1)
),
-- Bridge flow, and it is *not* the subgraph's `totalGRTMinted` / `totalGRTBurned`. Those count every
-- mint and burn, including the indexing rewards minted as a `Transfer` from the zero address; this
-- pair is the L1<->L2 bridge alone. `Transfer` is deliberately not indexed - see the comment on the
-- `graph_token` contract - so the bridge half is what a nest can state exactly today.
bridge AS (
  SELECT (SELECT SUM(CAST(amount AS HUGEINT)) FROM graph_token__bridge_minted) AS minted,
         (SELECT SUM(CAST(amount AS HUGEINT)) FROM graph_token__bridge_burned) AS burned
),
-- All-time totals, from the events. They were folded from `lodestar_epochs`, but `epoch_boundaries`
-- begins at epoch 1104 (the first `EpochRun` the nest holds) and 631M GRT of legacy `RewardsAssigned`
-- sit in epochs 113..1103, so the fold read 196M against the gateway's 837M. Summed from the events
-- both eras give 837,303,089 GRT, exact. Query fees follow the subgraph's own counter, which is gross
-- for the legacy era (`RebateCollected.tokens`, `AllocationCollected.tokens`) and net of only the 1%
-- protocol cut for Horizon (`tokensCollected - tokensCollected // 100`, truncated per event) - not the
-- indexer's net that `lodestar_epochs` and the deployments state. Measured to four digits, then exact.
epoch_totals AS (
  SELECT (SELECT SUM(CAST(amount AS HUGEINT)) FROM rewards__rewards_assigned)
         + (SELECT SUM(CAST(amount AS HUGEINT)) FROM rewards__horizon_rewards_assigned) AS indexing_rewards,
         (SELECT SUM(CAST(tokens AS HUGEINT)) FROM staking_legacy__rebate_collected)
         + (SELECT SUM(CAST(tokens AS HUGEINT)) FROM staking_legacy__allocation_collected)
         + (SELECT SUM(CAST("tokensCollected" AS HUGEINT) - CAST("tokensCollected" AS HUGEINT) // 100) FROM subgraph_service__query_fees_collected) AS query_fees
)
SELECT (SELECT total      FROM staked)     AS total_tokens_staked,
       -- the subgraph's `totalDelegatedTokens` is the pools net of thawing, and summing `lodestar_indexers`
       -- that way reproduced it to the wei (1,074,963,614 GRT); this view's own `delegation` netting
       -- lacks the rewards the pools accrue and read 626M. `delegated` still serves the delegator counts.
       (SELECT SUM(delegated_tokens - delegated_thawing_tokens) FROM lodestar_indexers) AS total_delegated_tokens,
       (SELECT total      FROM signalled)  AS total_tokens_signalled,
       (SELECT total      FROM allocated)  AS total_tokens_allocated,
       (SELECT raw        FROM supply)     AS total_supply_raw,
       (SELECT block_number FROM supply)   AS total_supply_at_block,
       (SELECT value      FROM supply)     AS total_supply,
       (SELECT value      FROM issuance)   AS issuance_per_block,
       (SELECT block_number FROM issuance) AS issuance_per_block_at_block,
       (SELECT minted     FROM bridge)     AS bridge_minted,
       (SELECT burned     FROM bridge)     AS bridge_burned,
       (SELECT indexing_rewards FROM epoch_totals) AS total_indexing_rewards,
       (SELECT query_fees FROM epoch_totals)       AS total_query_fees,
       (SELECT n_all      FROM staked)     AS indexer_count,
       (SELECT n_positive FROM staked)     AS staked_indexers_count,
       (SELECT n_all      FROM delegated)  AS delegator_count,
       (SELECT n_positive FROM delegated)  AS active_delegator_count,
       (SELECT n_all      FROM signalled)  AS curator_count,
       (SELECT n_positive FROM signalled)  AS active_curator_count,
       (SELECT n_all      FROM subgraphs)  AS subgraph_count,
       (SELECT n_active   FROM subgraphs)  AS active_subgraph_count,
       (SELECT MAX(epoch) FROM epoch_boundaries) AS current_epoch;

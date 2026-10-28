-- Lodestar's `SubgraphEpoch` shape (RFC-0011), served from events.
--
-- **The trap this view exists to avoid.** `EpochManager.epochLength` is 7,200, and the obvious move is
-- `start_block = anchor + (epoch - anchor_epoch) * 7200`. That is wrong on Arbitrum, and wrong by a
-- factor of ~48: inside an Arbitrum contract `block.number` returns the **L1** block number, so
-- EpochManager counts epochs in L1 blocks, while the `block_number` on an indexed log is **L2**.
-- Computing it gave 60,142 epochs where the network has 1,356.
--
-- `EpochRun` cannot rescue it either - it has fired **once** in the entire history, because running an
-- epoch is optional and nobody bothers.
--
-- So boundaries are derived from what the events themselves report. `AllocationCreated` and
-- `IndexingRewardsCollected` both carry `currentEpoch` alongside their L2 block, which is a direct
-- (epoch, L2 block) observation and needs no L1/L2 mapping at all. Our max epoch from these is 1,356,
-- which is exactly what the network subgraph reports.
CREATE VIEW epoch_boundaries AS
WITH observed AS (
  SELECT CAST("currentEpoch" AS HUGEINT) AS epoch, block_number
  FROM subgraph_service__allocation_created
  UNION ALL
  SELECT CAST("currentEpoch" AS HUGEINT), block_number
  FROM subgraph_service__indexing_rewards_collected
),
per_epoch AS (
  SELECT epoch, MIN(block_number) AS first_seen, MAX(block_number) AS last_seen
  FROM observed GROUP BY 1
),
-- **The boundaries, read off EpochManager's own arithmetic rather than guessed from events.**
--
-- The header above is still right that `start = anchor + (epoch - anchor_epoch) * 7200` is wrong in
-- L2 block space. It is exactly right in **L1** block space, which is the space EpochManager counts
-- in. Read at the tip, the contract reports `epochLength()` 7200, `lastLengthUpdateBlock()`
-- 16687937 and `lastLengthUpdateEpoch()` 92, so
--
--     epoch(l1) = 92 + (l1 - 16687937) // 7200
--
-- and because the last length update was at epoch 92, one linear segment covers this whole range -
-- no piecewise reconstruction. That formula reproduces `currentEpoch()` exactly at six L2 blocks
-- spanning 400M to 501M, and `currentEpochBlock()` returns 25889537, which is precisely the
-- formula's L1 start for epoch 1370. The contract agrees with the arithmetic about its own boundary.
--
-- The L1 boundary is then mapped to L2 by binary-searching for the first L2 block whose header
-- `l1BlockNumber` reaches it: 5,407 block fetches for all 266 boundaries, against the 459 million
-- an indexed `blocks` table would cost (RFC-0036 §4.2 fetches every block in the window, by design).
-- Every sampled boundary was checked against the contract: `currentEpoch()` returns E at the
-- boundary block and E-1 at the block before it. See nightswatchhq/nuthatch#1116. From 1371 every
-- row is checked that way, by `scripts/epoch-starts.sh`, which is the search.
--
-- **This table is static and spans epochs 1105 to 1401.** Epochs outside it fall back to the observed
-- derivation below and are labelled as such, so the view degrades rather than lying. An epoch is
-- about a day, so it goes stale daily; extending it is `scripts/epoch-starts.sh 1402 <current>`.
-- It cannot maintain itself yet: nuthatch keeps `l1_block_number` only on the `blocks` table, which
-- fetches every block in the window, and not on the log-bearing blocks this nest already reads.
exact_starts(epoch, start_block) AS (
  VALUES
    (1105, 409124579),
    (1106, 409474557),
    (1107, 409825292),
    (1108, 410174461),
    (1109, 410522194),
    (1110, 410869976),
    (1111, 411217938),
    (1112, 411565747),
    (1113, 411913984),
    (1114, 412262597),
    (1115, 412609656),
    (1116, 412956924),
    (1117, 413304255),
    (1118, 413652603),
    (1119, 414000685),
    (1120, 414349119),
    (1121, 414696038),
    (1122, 415043358),
    (1123, 415390288),
    (1124, 415737369),
    (1125, 416086027),
    (1126, 416434049),
    (1127, 416781133),
    (1128, 417128326),
    (1129, 417475601),
    (1130, 417822268),
    (1131, 418169917),
    (1132, 418517432),
    (1133, 418865109),
    (1134, 419213825),
    (1135, 419561287),
    (1136, 419908090),
    (1137, 420254021),
    (1138, 420601555),
    (1139, 420949151),
    (1140, 421297544),
    (1141, 421644936),
    (1142, 421991276),
    (1143, 422338055),
    (1144, 422684076),
    (1145, 423030680),
    (1146, 423377978),
    (1147, 423725247),
    (1148, 424073096),
    (1149, 424420598),
    (1150, 424767376),
    (1151, 425112629),
    (1152, 425459974),
    (1153, 425808036),
    (1154, 426155879),
    (1155, 426503853),
    (1156, 426852134),
    (1157, 427200615),
    (1158, 427549583),
    (1159, 427898518),
    (1160, 428247551),
    (1161, 428596965),
    (1162, 428947818),
    (1163, 429297747),
    (1164, 429646689),
    (1165, 429997482),
    (1166, 430346547),
    (1167, 430695177),
    (1168, 431044278),
    (1169, 431393092),
    (1170, 431741619),
    (1171, 432089233),
    (1172, 432437316),
    (1173, 432785199),
    (1174, 433133188),
    (1175, 433481169),
    (1176, 433829391),
    (1177, 434177298),
    (1178, 434524548),
    (1179, 434872546),
    (1180, 435220413),
    (1181, 435568522),
    (1182, 435916649),
    (1183, 436264744),
    (1184, 436612271),
    (1185, 436960825),
    (1186, 437308443),
    (1187, 437656738),
    (1188, 438004735),
    (1189, 438352856),
    (1190, 438700548),
    (1191, 439049718),
    (1192, 439397838),
    (1193, 439744688),
    (1194, 440092451),
    (1195, 440440597),
    (1196, 440787231),
    (1197, 441134814),
    (1198, 441481438),
    (1199, 441827978),
    (1200, 442172847),
    (1201, 442519442),
    (1202, 442866566),
    (1203, 443213761),
    (1204, 443561251),
    (1205, 443908343),
    (1206, 444255442),
    (1207, 444602921),
    (1208, 444950000),
    (1209, 445296930),
    (1210, 445644431),
    (1211, 445992452),
    (1212, 446340160),
    (1213, 446685976),
    (1214, 447030618),
    (1215, 447376523),
    (1216, 447723047),
    (1217, 448069895),
    (1218, 448416005),
    (1219, 448762198),
    (1220, 449107884),
    (1221, 449453885),
    (1222, 449801403),
    (1223, 450148611),
    (1224, 450495654),
    (1225, 450842657),
    (1226, 451189738),
    (1227, 451536513),
    (1228, 451882872),
    (1229, 452228190),
    (1230, 452573362),
    (1231, 452919034),
    (1232, 453264829),
    (1233, 453609989),
    (1234, 453955512),
    (1235, 454301014),
    (1236, 454643687),
    (1237, 454988877),
    (1238, 455336295),
    (1239, 455683150),
    (1240, 456027983),
    (1241, 456372404),
    (1242, 456718741),
    (1243, 457065388),
    (1244, 457410705),
    (1245, 457756949),
    (1246, 458103550),
    (1247, 458448292),
    (1248, 458790376),
    (1249, 459132833),
    (1250, 459479825),
    (1251, 459825370),
    (1252, 460171183),
    (1253, 460516766),
    (1254, 460862419),
    (1255, 461207550),
    (1256, 461554204),
    (1257, 461900364),
    (1258, 462245878),
    (1259, 462593059),
    (1260, 462939933),
    (1261, 463285798),
    (1262, 463628947),
    (1263, 463973418),
    (1264, 464319256),
    (1265, 464664483),
    (1266, 465010749),
    (1267, 465355955),
    (1268, 465700901),
    (1269, 466044535),
    (1270, 466387661),
    (1271, 466730395),
    (1272, 467075376),
    (1273, 467421631),
    (1274, 467767728),
    (1275, 468113582),
    (1276, 468458499),
    (1277, 468803001),
    (1278, 469148924),
    (1279, 469496202),
    (1280, 469843826),
    (1281, 470191656),
    (1282, 470540180),
    (1283, 470884787),
    (1284, 471229646),
    (1285, 471573861),
    (1286, 471919463),
    (1287, 472264990),
    (1288, 472610988),
    (1289, 472956673),
    (1290, 473299720),
    (1291, 473643935),
    (1292, 473988831),
    (1293, 474331908),
    (1294, 474677055),
    (1295, 475022363),
    (1296, 475367154),
    (1297, 475712399),
    (1298, 476059327),
    (1299, 476406214),
    (1300, 476753407),
    (1301, 477101419),
    (1302, 477449353),
    (1303, 477796763),
    (1304, 478143752),
    (1305, 478491220),
    (1306, 478838716),
    (1307, 479186169),
    (1308, 479533867),
    (1309, 479881782),
    (1310, 480228358),
    (1311, 480575901),
    (1312, 480923184),
    (1313, 481269925),
    (1314, 481616707),
    (1315, 481964060),
    (1316, 482311734),
    (1317, 482658477),
    (1318, 483005724),
    (1319, 483352537),
    (1320, 483699743),
    (1321, 484047177),
    (1322, 484394098),
    (1323, 484740625),
    (1324, 485087064),
    (1325, 485433569),
    (1326, 485780390),
    (1327, 486127376),
    (1328, 486474062),
    (1329, 486820762),
    (1330, 487167899),
    (1331, 487514380),
    (1332, 487859735),
    (1333, 488206502),
    (1334, 488553403),
    (1335, 488900266),
    (1336, 489246549),
    (1337, 489593224),
    (1338, 489939948),
    (1339, 490285420),
    (1340, 490629661),
    (1341, 490975360),
    (1342, 491321230),
    (1343, 491667234),
    (1344, 492012615),
    (1345, 492358435),
    (1346, 492702008),
    (1347, 493046521),
    (1348, 493392434),
    (1349, 493737939),
    (1350, 494081962),
    (1351, 494427277),
    (1352, 494772464),
    (1353, 495116037),
    (1354, 495459386),
    (1355, 495804075),
    (1356, 496148119),
    (1357, 496494341),
    (1358, 496840971),
    (1359, 497187470),
    (1360, 497531422),
    (1361, 497875935),
    (1362, 498221121),
    (1363, 498564843),
    (1364, 498906669),
    (1365, 499251341),
    (1366, 499595800),
    (1367, 499938326),
    (1368, 500283436),
    (1369, 500629598),
    (1370, 500973867),
    (1371, 501317707),
    (1372, 501662756),
    (1373, 502001069),
    (1374, 502341541),
    (1375, 502680841),
    (1376, 503026063),
    (1377, 503371274),
    (1378, 503715985),
    (1379, 504057934),
    (1380, 504403776),
    (1381, 504745243),
    (1382, 505086706),
    (1383, 505430543),
    (1384, 505771243),
    (1385, 506110514),
    (1386, 506452890),
    (1387, 506792546),
    (1388, 507125771),
    (1389, 507463555),
    (1390, 507806359),
    (1391, 508147452),
    (1392, 508470078),
    (1393, 508793859),
    (1394, 509112776),
    (1395, 509423357),
    (1396, 509742026),
    (1397, 510065486),
    (1398, 510384469),
    (1399, 510700115),
    (1400, 511025871),
    (1401, 511341461)
),
-- **Every epoch in the exact range gets a row, observed or not.** The observed-only derivation could
-- not do this: an epoch with no `AllocationCreated` and no `IndexingRewardsCollected` produced no
-- row at all. Its blocks were not dropped - the `LEAD` rule above stretched the *predecessor's*
-- `end_block` straight across the missing epoch, so everything inside it was filed one epoch out.
-- The same misplacement as the gap problem, and it conserves for the same reason. It is **not** an
-- explanation for #1117's non-conserving residue, and should not be offered as one.
boundaries AS (
  SELECT CAST(x.epoch AS HUGEINT) AS epoch,
         CAST(x.start_block AS BIGINT) AS start_block,
         'l1-exact' AS boundary_source
  FROM exact_starts x
  UNION ALL
  SELECT p.epoch, CAST(p.first_seen AS BIGINT), 'observed'
  FROM per_epoch p
  WHERE NOT EXISTS (SELECT 1 FROM exact_starts x WHERE CAST(x.epoch AS HUGEINT) = p.epoch)
)
SELECT b.epoch,
       b.start_block,
       -- An epoch ends where the next one starts. The newest has no successor yet, so it runs to its
       -- own last observation - open-ended rather than wrong.
       COALESCE(LEAD(b.start_block) OVER (ORDER BY b.epoch) - 1, p.last_seen, b.start_block) AS end_block,
       -- for bucketing: the newest epoch takes everything after it too, or the current epoch's fees
       -- and signal read 0 until the next `EpochRun` (nuthatch#1160)
       COALESCE(LEAD(b.start_block) OVER (ORDER BY b.epoch) - 1, 9223372036854775807) AS until_block,
       p.last_seen,
       -- Zero where the boundary is exact: there is no unobserved window left to warn about. For an
       -- observed row it keeps its old meaning, the width of the gap the true start could lie in.
       CASE WHEN b.boundary_source = 'l1-exact' THEN 0
            ELSE COALESCE(p.first_seen - LAG(p.last_seen) OVER (ORDER BY b.epoch) - 1, 0)
       END AS unobserved_gap_blocks,
       b.boundary_source
FROM boundaries b
LEFT JOIN per_epoch p ON p.epoch = b.epoch;

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
-- epoch out by the observed-boundary problem described above, not value lost.
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

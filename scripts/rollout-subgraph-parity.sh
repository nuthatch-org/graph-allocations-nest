#!/usr/bin/env bash
# Install the network-subgraph parity fixes on production (8107, graph-allocations-nest-next):
# signal counted as the pools hold it (91), and the oldest `AllocationCollected` read as its
# `rebateFees` (40, 50, 90, 95).
#
# No restart and no re-index: /sql reads views/*.sql from disk per statement, and views/ is outside
# the nest's data identity. Every file must be the one this was written against before anything is
# touched, so none of them is overwritten blind.
set -euo pipefail

HOST=${HOST:-root@89.167.109.4}
KEY=${KEY:-$HOME/.ssh/hetzner_drpc}
NEST=/opt/nuthatch/graph-allocations-nest-next
PORT=8107
SUBGRAPH=https://subgraphs.graphops.xyz/v1/subgraphId/DZz4kDTdmzWLWsV373w2bSmoar3umKKH9y82SUKr5qmp
# installed path, source in this repo, production's current sha256, the replacement's sha256.
# Production runs its own 50 and 95 (portable epochs, and 95 from before the denylist), so their
# replacements are production's files with the same one-line fix, kept in scripts/production/.
FILES=(
  views/40-lodestar-allocations.sql views/40-lodestar-allocations.sql d21f71e601de00360679247ae87ccef3d46819c0587a284241cc608198681f68 53401554a6a7c10c6da20f05a150549e9e7141f37d6a8a2da5937466ffe623a3
  views/50-lodestar-epochs.sql scripts/production/50-lodestar-epochs.sql 491e9ffb0e3f5e4abe01b82130146808cd46ed990cdbacbb23e1d72dcdd8b6a3 5734cd2687af50a3883d16a3e96d6aeb7e44a746971e47a893ff1539b34d7d31
  views/90-lodestar-indexers.sql views/90-lodestar-indexers.sql 4b7d418171b73ff6c6ab9cc14cf5c368520552108e47122437a14f1d14f33153 0b65cbe8b402eff59054caaa1ca21ed172d8de64808ce51fd95e914cff5aff99
  views/91-lodestar-network.sql views/91-lodestar-network.sql 739229baa48d885d93dd347bda2d3bdf2a0535f0f3c915a19d3e8157e24bfc4e 413b60d2d0c5b9d72c3fa0a582e3df7b9dff2bc993774d388663348e67ac3214
  views/95-lodestar-deployments.sql scripts/production/95-lodestar-deployments.sql 6d7614bb894ee3dda46277a4d1b89ba6a60fa110f6c70c9f5fac5d8dfb3b2403 3dd9ce9a133f3dd73ad47e51627d555c991c40c7c27beae979cadf03a3f570ac
)

root="$(cd "$(dirname "$0")/.." && pwd)"
bak="$NEST.views-bak-$(date -u +%Y%m%dT%H%M%SZ)"
remote() { ssh -i "$KEY" -o BatchMode=yes "$HOST" "$@"; }
rollback="ssh -i $KEY $HOST 'cp -p $bak/*.sql $NEST/views/'"
[ -n "${GRAPHOPS_SUBGRAPHS_KEY:-}" ] || { echo "GRAPHOPS_SUBGRAPHS_KEY is not set" >&2; exit 1; }

checks=""
for ((i = 0; i < ${#FILES[@]}; i += 4)); do
  f=${FILES[i]} src=${FILES[i+1]} old=${FILES[i+2]} new=${FILES[i+3]}
  have=$(shasum -a 256 "$root/$src" | cut -d' ' -f1)
  [ "$have" = "$new" ] || { echo "local $src is $have, not the expected replacement" >&2; exit 1; }
  checks+="cur=\$(sha256sum $NEST/$f | cut -d' ' -f1); [ \"\$cur\" = $old ] || [ \"\$cur\" = $new ] || { echo \"production $f is \$cur, not the file this was written against; stopping\" >&2; exit 1; }
"
done
remote "set -e
$checks
cp -a $NEST/views $bak"
echo "backed up $NEST/views to $bak"

for ((i = 0; i < ${#FILES[@]}; i += 4)); do
  f=${FILES[i]} src=${FILES[i+1]} new=${FILES[i+3]} tmp="$(dirname "$f")/.$(basename "$f").new"
  remote "set -e
    cat > $NEST/$tmp
    chown --reference=$NEST/$f $NEST/$tmp
    chmod --reference=$NEST/$f $NEST/$tmp
    mv -f $NEST/$tmp $NEST/$f
    [ \"\$(sha256sum $NEST/$f | cut -d' ' -f1)\" = $new ]" < "$root/$src"
  echo "installed $f"
done

# The statement goes over stdin, so its quotes never meet the remote shell.
sql() { printf '%s' "$1" | remote "curl -sS -m 300 -G 127.0.0.1:$PORT/sql --data-urlencode q@-"; }
gql() { curl -sS -m 60 "$SUBGRAPH" -H "Authorization: Bearer $GRAPHOPS_SUBGRAPHS_KEY" -H 'content-type: application/json' -d "$1"; }
fail() { echo "FAILED: $1" >&2; echo "rollback: $rollback" >&2; exit 1; }

# Signal moves with every Collected, so the two reads agree to 0.001%.
ours=$(sql "SELECT CAST(total_tokens_signalled AS VARCHAR) AS s FROM lodestar_network" | jq -r '.rows[0].s')
theirs=$(gql '{"query":"{ graphNetwork(id: \"1\") { totalTokensSignalled } }"}' | jq -r '.data.graphNetwork.totalTokensSignalled')
python3 -c "import sys; a,b=int(sys.argv[1]),int(sys.argv[2]); sys.exit(0 if abs(a-b)*100000 <= max(a,b) else 1)" "$ours" "$theirs" \
  || fail "total_tokens_signalled $ours against the subgraph's $theirs"
echo "ok: total_tokens_signalled $ours, the subgraph's $theirs"

# Settled history, so exact: an indexer and an epoch that only the oldest event paid.
ix=0x0b9d582b7fdd387ba13ad7f453d49af255a8ed5e
ours=$(sql "SELECT CAST(query_fees_collected AS VARCHAR) AS q FROM lodestar_indexers WHERE id = '$ix'" | jq -r '.rows[0].q')
theirs=$(gql "{\"query\":\"{ indexer(id: \\\"$ix\\\") { queryFeesCollected } }\"}" | jq -r '.data.indexer.queryFeesCollected')
[ "$ours" = "$theirs" ] || fail "indexer $ix query fees $ours against the subgraph's $theirs"
echo "ok: indexer $ix query fees $ours, exact"
ours=$(sql "SELECT CAST(query_fees_collected AS VARCHAR) AS q FROM lodestar_epochs WHERE id = 145" | jq -r '.rows[0].q')
theirs=$(gql '{"query":"{ epoch(id: \"145\") { queryFeesCollected } }"}' | jq -r '.data.epoch.queryFeesCollected')
[ "$ours" = "$theirs" ] || fail "epoch 145 query fees $ours against the subgraph's $theirs"
echo "ok: epoch 145 query fees $ours, exact"
echo "rollback, if wanted: $rollback"

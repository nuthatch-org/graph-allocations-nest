#!/usr/bin/env bash
# Install the pool-based total_tokens_signalled on production (8107, graph-allocations-nest-next).
#
# No restart and no re-index: /sql reads views/*.sql from disk per statement, and views/ is outside
# the nest's data identity. Stops if production's file is not main's, since production has run
# portable variants of other views and this one must not be overwritten blind.
set -euo pipefail

HOST=${HOST:-root@89.167.109.4}
KEY=${KEY:-$HOME/.ssh/hetzner_drpc}
NEST=/opt/nuthatch/graph-allocations-nest-next
PORT=8107
FILE=views/91-lodestar-network.sql
OLD=739229baa48d885d93dd347bda2d3bdf2a0535f0f3c915a19d3e8157e24bfc4e   # main's file
NEW=413b60d2d0c5b9d72c3fa0a582e3df7b9dff2bc993774d388663348e67ac3214   # this branch's file
SUBGRAPH=https://subgraphs.graphops.xyz/v1/subgraphId/DZz4kDTdmzWLWsV373w2bSmoar3umKKH9y82SUKr5qmp

src="$(cd "$(dirname "$0")/.." && pwd)/$FILE"
bak="$NEST.views-bak-$(date -u +%Y%m%dT%H%M%SZ)"
remote() { ssh -i "$KEY" -o BatchMode=yes "$HOST" "$@"; }
rollback="ssh -i $KEY $HOST 'cp -p $bak/91-lodestar-network.sql $NEST/$FILE'"

have=$(shasum -a 256 "$src" | cut -d' ' -f1)
[ "$have" = "$NEW" ] || { echo "local $FILE is $have, not this branch's file" >&2; exit 1; }
[ -n "${GRAPHOPS_SUBGRAPHS_KEY:-}" ] || { echo "GRAPHOPS_SUBGRAPHS_KEY is not set" >&2; exit 1; }

remote "set -e
  cur=\$(sha256sum $NEST/$FILE | cut -d' ' -f1)
  [ \"\$cur\" = $OLD ] || [ \"\$cur\" = $NEW ] || { echo \"production $FILE is \$cur, not main's; stopping\" >&2; exit 1; }
  cp -a $NEST/views $bak"
echo "backed up $NEST/views to $bak"

remote "set -e
  cat > $NEST/views/.91-lodestar-network.new
  chown --reference=$NEST/$FILE $NEST/views/.91-lodestar-network.new
  chmod --reference=$NEST/$FILE $NEST/views/.91-lodestar-network.new
  mv -f $NEST/views/.91-lodestar-network.new $NEST/$FILE
  [ \"\$(sha256sum $NEST/$FILE | cut -d' ' -f1)\" = $NEW ]" < "$src"
echo "installed $FILE ($NEW)"

ours=$(remote "curl -sS -m 300 -G 127.0.0.1:$PORT/sql --data-urlencode 'q=SELECT CAST(total_tokens_signalled AS VARCHAR) AS s FROM lodestar_network'" \
  | jq -r '.rows[0].s // .error // "no answer"')
theirs=$(curl -sS -m 30 "$SUBGRAPH" -H "Authorization: Bearer $GRAPHOPS_SUBGRAPHS_KEY" -H 'content-type: application/json' \
  -d '{"query":"{ graphNetwork(id: \"1\") { totalTokensSignalled } }"}' | jq -r '.data.graphNetwork.totalTokensSignalled')
# The two reads are moments apart and Collected fires constantly, so agreement is to 0.001%.
if python3 -c "import sys; a,b=int(sys.argv[1]),int(sys.argv[2]); sys.exit(0 if abs(a-b)*100000 <= max(a,b) else 1)" "$ours" "$theirs"; then
  echo "ok: total_tokens_signalled $ours, the subgraph's $theirs"
  echo "rollback, if wanted: $rollback"
else
  echo "FAILED: ours '$ours', the subgraph's '$theirs'" >&2
  echo "rollback: $rollback" >&2
  exit 1
fi

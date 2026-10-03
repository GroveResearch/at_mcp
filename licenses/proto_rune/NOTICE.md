# Adapted proto_rune code

`lib/at_mcp/atproto/dsl.ex` adapts the authenticated query/procedure and
parameter-declaration code from `ProtoRune.XRPC.DSL` in the released
[proto_rune 0.5.3](https://hex.pm/packages/proto_rune/0.5.3) package.
Its original MIT copyright and permission notice is copied without changes
from that package’s `LICENSE` into this directory.

at_mcp resolves application NSIDs at runtime, separates declarations from
request execution, and adds network AppView routing. The adapted code keeps
its upstream MIT attribution; at_mcp’s root license does not replace it.

Upstream source: <https://github.com/zoedsoupe/proto_rune>.

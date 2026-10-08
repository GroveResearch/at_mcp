# Vendored lexicons

These are copies of the record lexicons `AtMcp.Network` derives limits from.
They are copies because the namespaces they come from are not AtMcp's
dependencies: `app.bsky.*` lives in the `atproto` repository and `town.delve.*`
in `delvetown-atproto`/`delvetown-sdk`, neither of which is on the machine of
someone who installs AtMcp. A limit that AtMcp must enforce before it sends
anything has to be present in AtMcp.

The alternative is transcribing four numbers into Elixir, which is the
re-derivation this constellation's first idiom warns about: the lexicon is the
upstream declaration, so the numbers are read from it rather than copied out of
it. `AtMcp.Network` reads them at compile time, so a release carries no runtime
dependency on this directory, and `test/at_mcp/network_test.exs` parses the same
files independently and fails if the compiled numbers drift from them.

Only the definitions AtMcp reads a limit from are here — currently
`feed/post.json` and `embed/images.json` for each network. The image limits
size the MCP endpoint's request body (`AtMcp.MCP.HTTP.body_limit/0`). Do not vendor a whole namespace: the 165-NSID
rename is one substitution rule, and a rule does not need 165 copies to state it.

Copied from `deepfates/delvetown-sdk` at `7cb95ba` (`feed/post.json` on
2026-09-11, `embed/images.json` on 2026-10-07), which holds both
namespaces side by side. Refresh them by copying again, not by editing them.

Upstream copyright and license terms are retained in
[`licenses/lexicons`](../../licenses/lexicons/NOTICE.md). These copied files
are not relicensed by at_mcp’s root license.

# Vendored lexicon attribution

The `priv/lexicons/**/feed/post.json` and `priv/lexicons/**/embed/images.json`
files are copied without changes from `delvetown-sdk` commit
`7cb95ba89a452220dc7988fc4386b75004ae32bb`, as recorded in
`priv/lexicons/README.md`. Their upstream files are the same paths under
`lexicons/`. The `town/delve` copies are Delvetown’s adapted application
namespace and limits.

The upstream copyright and choice of MIT or Apache-2.0 terms are preserved
unmodified in `LICENSE.txt`, `LICENSE-MIT.txt` and `LICENSE-APACHE.txt` beside
this notice. They apply independently of at_mcp’s own MIT license.

Upstream AT Protocol lexicons: <https://github.com/bluesky-social/atproto>.
These declarations are retained as source in both the package and release;
`AtMcp.Network` derives the network’s post and image limits from them.

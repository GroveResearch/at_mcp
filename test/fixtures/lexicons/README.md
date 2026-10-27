# Lexicons the record tests check against

Read by `AtMcp.Test.Lexicon`, which checks that a record or a procedure's
input AtMcp sends matches its lexicon. Only the lexicons those tests name are
here; `priv/lexicons` holds the ones `AtMcp.Network` reads limits from.

Copied unchanged from `bluesky-social/atproto` at
`9f66a7e54b030700c03eda0bdbf35ffe756f4cd8`: `app/bsky/**` from
`packages/bsky/lexicons/`, `com/atproto/**` from `lexicons/`. Refresh them by
copying again, not by editing them. They are written in the `app.bsky`
namespace; the checker reads another network's `$type`s back into it.

Upstream copyright and license terms are in
[`licenses/lexicons`](../../../licenses/lexicons/NOTICE.md).

`town/delve/actor/profile.json` is copied unchanged from Delvetown's own
lexicon for `town.delve.actor.profile`. Town's signed `presentation` field
is deliberately absent from the Bluesky profile schema, so Town Save tests
use this canonical declaration rather than treating the profiles as identical.

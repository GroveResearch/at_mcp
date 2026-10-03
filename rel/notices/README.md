# Binary release notices

The release hook in `rel/notices.exs` copies dependency notices from the fetched
sources for applications actually present in the assembled release. It retains
README license sections as well as root license and notice files. CAStore,
Ecto and NimblePool ship their Apache notice in README; the full Apache text
comes from the runtime's upstream license distribution. MintWebSocket's Hex
archive omits its LICENSE, so its exact upstream text is retained here.

Runtime directories contain unmodified license files from the named upstream
OTP and Elixir tags. `SOURCE` gives the source and archive checksum. The OTP set
includes its aggregate license directory and the separate notices for bundled
AsmJit, PCRE, Ryu, zlib, zstd and its embedded OpenSSL code. The runtime-wide
upstream set can include terms for optional components that are not enabled.
OpenSSL's separate notice covers the crypto provider, statically bundled by
CI's runtime builds and dynamically linked by some local installations.

A runtime update needs the corresponding upstream notice set here. The build
fails when that set or a dependency's notice is absent. It needs no network to
collect notices. `licenses/bundled/APPLICATIONS` records the assembled apps;
`SHA256SUMS` lets the distribution check detect missing or altered notice files.
Source attribution for code maintained in this project remains in `licenses/`.

These files retain upstream notices; they do not constitute legal certification.

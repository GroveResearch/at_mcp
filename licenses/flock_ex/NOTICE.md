# Native lock attribution

`c_src/native_lock.c`, the initial `AtMcp.NativeLock` wrapper, and the Makefile
are derived from [flock_ex 0.1.0](https://hex.pm/packages/flock_ex/0.1.0),
by nippynetworks / Ed Wildgoose, under Apache-2.0. The complete upstream license
is preserved beside this notice. These files retain that license independently
of the application's license.

AtMcp modified the implementation to initialize binary paths, reject embedded
NULs, remove the 255-byte path limit, serialize descriptor cleanup, open private
close-on-exec descriptors, handle allocation/monitor failures, and support
`monitor_owner: false`. Application ownership retains that unmonitored resource
across Erlang process death until protected writers stop. The implementation
moved from a vendored dependency to application ownership for Hex distribution;
there is no second copy or separate flock_ex runtime application.

Upstream source: https://github.com/nippynetworks/flock_ex. Do not unlink a
lockfile when releasing it: another process must contend on the same inode.

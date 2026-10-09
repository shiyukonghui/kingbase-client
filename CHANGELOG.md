# Changelog

Versions follow Semantic Versioning, and every rule the dialect layer states carries
the evidence it was obtained from — `measured` on a live instance, or `documented`
from the KingbaseES manuals and not yet observed.

## 0.1.0

First release.

- PostgreSQL wire protocol 3.0 over the simple query protocol: startup, SASL and
  SCRAM-SHA-256 authentication, plaintext transport (`SSLRequest` answered `N`),
  `ErrorResponse` / `NoticeResponse` / `ParameterStatus` handling, and a
  `ReadyForQuery` drain that keeps the session usable after any server refusal.
- `COPY FROM STDIN` in text and binary formats, with a `CopyRow` buffer writer that
  escapes fields the way the server reads them.
- A dialect layer for the four `database_mode` compatibility modes, built from the
  settings a connected instance reports rather than from the mode name: column type
  per kind, identifier quoting, pagination clause, concatenation operator, boolean
  and empty-string text, catalog view prefix, integer-sum widening, current-time
  expression, and the transaction-opening statement.
- `ResultSet::affected` reads the row count out of a command tag, so DML does not
  have to read a table back to know what changed.
- Native target only: `moon.mod.json` declares `preferred-target` and
  `supported-targets` as `native`, because the socket bindings are a C file
  (`sys/stub.c`) that no other backend compiles.
- 30 offline tests; no test opens a socket.

Measured on one KingbaseES V009R001C010 instance per mode (`pg`, `oracle`, `mysql`,
`sqlserver`) on 2026-10-09. The four modes were checked by `livecheck` (14 dialect
rules) and `crud` (37 DML checks) in the companion benchmark repository, and every
difference that measurement overturned is recorded in `README.mbt.md`: sqlserver
mode's `sum(integer)` returning `int` and wrapping, `pg` mode shipping no `sys_*`
catalog view, mysql mode printing `t` for a boolean, `getdate()` refused everywhere,
and sqlserver mode refusing bare `begin`.

The extended query protocol is refused by this deployment in all four modes, so the
client does not use it; `Dialect::extended_protocol_supported` reports that per mode.

# shiyukonghui/kingbase-client

A KingbaseES client for MoonBit: PostgreSQL wire protocol 3.0, SCRAM-SHA-256 and
plaintext authentication, `COPY FROM STDIN` for bulk loading, and a dialect layer
for the four KingbaseES compatibility modes (`pg`, `oracle`, `mysql`, `sqlserver`).

Written for, and measured against, KingbaseES V009R001C010
(`server_version 12.1`).

## Install

Path dependency, next to this checkout:

```json
{
  "deps": {
    "shiyukonghui/kingbase-client": { "path": "../kingbase-client" }
  }
}
```

From the registry:

```sh
moon add shiyukonghui/kingbase-client
```

In a package that uses it — the imports go in a `moon.pkg` file, because during
development the JSON package-config form resolved path aliases wrongly:

```
import {
  "shiyukonghui/kingbase-client" @kb,
  "shiyukonghui/kingbase-client/dialect" @dialect,
}
```

## Requirements

The `sys` package talks to the socket through a small C file
(`sys/stub.c`), so the client builds for the **native** target only. On Windows
the Microsoft toolchain environment has to be set before `moon` runs;
`native.cmd` does that and forwards its arguments, so use
`cmd //c "native.cmd test --target native"`.

TLS is not implemented: the client sends `SSLRequest`, accepts the server's `N`
answer, and continues in plaintext. That is what this deployment offers.

## Use

```moonbit nocheck
let cfg = @kb.new_config("db.example.com", 54321, "app", secret, "app")
let client = @kb.connect(cfg)
let rs = client.query("select id, amount from mb_orders where id = 42")
println(rs.cell(0, 1))
client.close()
```

Every value comes back as the server's own text, which is why a mode that prints
a timestamp differently cannot break a read. `ResultSet.scalar()`,
`first_text(col)` and `pairs()` cover the common shapes.

Bulk loading writes a batch of rows into a reusable buffer and streams it:

```moonbit nocheck
let stream = client.copy_in("copy mb_orders (id, name, amount) from stdin")
let row = @kb.new_copy_row(@buffer.new(size_hint=1024))
row.write_int64(7L)
row.write_text("product-1")
row.write_decimal(1234567L, 4) // numeric(18,4) -> 123.4567
row.end_row()
stream.send_data(row.take())
println(stream.finish()) // "COPY 1"
```

`CopyRow::start_field` hands over the underlying buffer for a value that is
cheaper to write as bytes than to build as a `String`.

DML reads the row count out of the command tag, and opens a transaction with the
spelling the connected mode takes:

```moonbit nocheck
let d = client.dialect()
let n = client.query("update mb_orders set status = 'closed' where id <= 1000").affected()
println(n) // 1000 -- "UPDATE 1000"; `SELECT 1` and `COPY 5000` parse the same way
client.execute(d.begin_statement()) // "begin", or "begin transaction" in sqlserver mode
client.execute("commit")
```

`affected()` returns 0 for a command that reports no rows, such as `SHOW` or
`SET`.

## The four modes

`database_mode` is an *internal* setting chosen at `initdb`
(`initdb -m sqlserver`), so one instance has one mode and it cannot be switched
per session. The client reads it, together with the settings that refine it,
during `connect`, and stores the result as a `Dialect`:

```moonbit nocheck
let d = client.dialect()
println(d.mode) // Sqlserver
println(d.setting("sql_mode")) // ONLY_FULL_GROUP_BY,ANSI_QUOTES
println(d.column_type(@dialect.Timestamp)) // datetime
println(d.limit_clause(100, 500)) // offset 500 rows fetch next 100 rows only
```

`new_config_fixed_mode` skips that read when the mode is already known.

Two rules shape the layer:

1. Behaviour is read from settings, not assumed from the mode name.
   `enable_ci`, `ora_input_emptystr_isnull`, `quoted_identifier`, `sql_mode`,
   `copy_mode`, `DateStyle`, `DateFormat` and
   `standard_conforming_strings` each decide a rule the mode name alone would
   only guess at. Not every mode defines every name, so the client reads the
   catalog view first, then `show` for each name still missing, and treats a
   refusal as "this mode has no such setting" rather than as a failure.
2. Every rule carries its evidence in a comment: `measured` (observed on a live
   instance) or `documented` (manual only). All four modes below have been
   measured against one instance each on 2026-10-09.

| Rule | pg | oracle | mysql | sqlserver |
| --- | --- | --- | --- | --- |
| integer type | `integer` | `number(10)` | `int` | `int` |
| big integer | `bigint` | `number(19)` | `bigint` | `bigint` |
| date-and-time type | `timestamp` | `timestamp` | `datetime` | `datetime` |
| boolean column type | `boolean` | `number(1)` | `boolean` | `bit` |
| boolean text, read back after a COPY round trip | `t` / `f` | `1` / `0` | `t` / `f` | `1` / `0` |
| `''` stored in a varchar | not NULL | NULL | not NULL | not NULL |
| pagination the dialect emits | `limit n offset m` | `offset m rows fetch next n rows only` | `limit n offset m` | `offset m rows fetch next n rows only` |
| also accepted there | `offset/fetch` | `top`, `limit m,n`, `rownum` | `top`, `limit m,n`, `rownum` | `top`, `limit m,n` |
| identifier quoting | `"x"` | `"x"` | `"x"` and `` `x` `` | `"x"` and `[x]` |
| string concatenation | `\|\|` | `\|\|` | `concat()` | `+` (`\|\|` refused under `ANSI_QUOTES`) |
| catalog views | `pg_*` only | `sys_*` and `pg_*` | `sys_*` and `pg_*` | `sys_*` and `pg_*` |
| opens a transaction | `begin` | `begin` | `begin` | `begin transaction` only |
| return type of `sum(integer)` | `bigint` | `numeric` | `bigint` | **`int`** |
| `smalldatetime` | absent | absent | absent | present |
| `varchar2` / `number` | absent | present | present | absent |

Every column in that table is a rule the dialect encodes, and `sqlserver` mode's
`sum` row is a correctness trap: `sum(int)` there returns `int`, so a total over
more than about 2 billion silently wraps instead of raising. The same 1M rows
aggregate to `1335346292` in sqlserver mode and `9925280884` in the other three —
the difference is exactly `2^33`. `Dialect::wide_sum` casts where it must, which is
why benchmark checksums are comparable between modes.

## Measured limits, in all four modes

- The extended query protocol is refused everywhere: a lone `Parse` message
  answers `08P01` ("insufficient data left in message"), from this library and
  from an independent implementation alike. The session survives it. The simple
  protocol is what the client uses.
- `COPY ... FROM STDIN WITH (FORMAT BINARY)` works in all four modes: a `PGCOPY`
  image loads and reads back correctly. `WITH (BINARY)` is *not* a valid option
  and answers 42601. `Dialect::binary_copy_supported` reports it.
- Prepared statements are reachable as SQL. A parameterised one
  (`prepare p(int) as select $1 + 1; execute p(41)`) runs in every mode. A
  parameterless one runs in pg, oracle and mysql mode, but sqlserver mode reads
  `execute p` as a stored-procedure call (`42883`) and `execute p()` as a syntax
  error (`42601`).
- `getdate()` — the SQL Server form — is refused in all four modes; `now()`
  answers everywhere and is what `Dialect::now_expression` returns.
- `sqlserver` mode refuses bare `begin` (`42601`, "syntax error at end of
  input"), because there the word opens a `BEGIN ... END` block. `begin
  transaction` opens one in all four modes, and `begin tran` — SQL Server's
  abbreviation — only in that one. `commit` and `rollback` are bare-safe
  everywhere, so only the opening statement needs a dialect:
  `Dialect::begin_statement`.
- In `sqlserver` mode a column declared `timestamp` is the rowversion type, not
  a time: `cast('2022-01-01 10:20:30' as timestamp)` yields `0x323032322D30312D`.
  Use `datetime`, which the dialect does.
- Text output differs per mode and per function: pg mode prints a UTC offset for
  both `now()` and `current_timestamp`, sqlserver mode prints one for `now()` but
  none for `current_timestamp`, mysql mode prints none for either. The client
  therefore returns values as text and parses nothing.

## Validating an instance

The companion benchmark repository (`KingBase-Test`) ships three commands, all
taking the usual connection options:

```text
kingbase_bench probe     --host=IP --port=PORT --user=NAME --password=SECRET --database=NAME   # 52 read-only checks
kingbase_bench livecheck --host=IP ...                                                        # 14 dialect rules, one verdict each
kingbase_bench crud      --host=IP ...                                                        # 37 single-row and batch DML checks
```

`livecheck` and `crud` have been run against one instance per mode. The first
reports `all 14 dialect rules hold` in pg, oracle, mysql and sqlserver mode; the
second reports `37 CRUD checks passed` in each. `crud` is the DML half of the
library — `INSERT`, `UPDATE`, `DELETE`, `ResultSet::affected`, boolean and
empty-string literals, and transactions — which is also where the `begin`
refusal in sqlserver mode was found. Both write only session temp tables, which
the server drops when the connection closes. The probe output and the two verdict
tables are archived in that repository under `docs/data/probe-<mode>.txt`,
`docs/data/mode-matrix.txt` and `docs/data/crud-matrix.txt`.

## Tests

`native.cmd test --target native` runs the offline suite (30 tests): mode
mapping, per-mode type names, pagination and concatenation, identifier quoting,
NULL and boolean text, catalog view names, integer-sum widening, transaction
spellings, COPY field escaping, command-tag row counts, and the SCRAM vectors. No
test opens a socket, so the suite passes without a server.

## Release

`CHANGELOG.md` records what each version contains; `moon.mod.json` carries the
version, and it must be higher than any version already on the registry.

`moon.mod.json` sets `preferred-target` and `supported-targets` to `native`, which
is what makes `moon package` and `moon publish` work at all: without it `moon`
checks the default `wasm-gc` target, and `sys/stub.c` bindings do not compile
there. The declared target set also tells a consumer, in machine-readable form,
that this module is native-only.

Before a release, in this order:

```sh
cmd //c "native.cmd check --target native"        # 0 errors, 0 warnings
cmd //c "native.cmd test  --target native"        # the offline suite
cmd //c "native.cmd info  --target native"        # regenerate pkg.generated.mbti
moon package --list                               # what would be uploaded
```

`moon package --list` runs the check and prints the archive contents; `sys/stub.c`
has to be in that list, because a consumer cannot build the client without it.
`_build/` is never uploaded, and neither is a dotfile.

Publishing needs a registry account, and the module name already carries it: a
mooncakes module name must begin with the publisher's username, which is why this
module is `shiyukonghui/kingbase-client`.

```sh
moon register          # once, at https://mooncakes.io
moon login             # writes ~/.moon/credentials.json
moon publish           # version must be SemVer and higher than any published one
```

No unpublish or delete command is documented, so a published version is effectively
permanent. Bump `version` in `moon.mod.json` and add a `CHANGELOG.md` entry in the
same commit, then tag it.


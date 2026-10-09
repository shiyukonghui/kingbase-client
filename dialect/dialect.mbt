///| SQL dialect rules for the four KingbaseES compatibility modes.
///|
///| KingbaseES fixes its dialect at `initdb` time and reports it in the
///| `database_mode` GUC. Measured on the target instance:
///|
///| ```text
///| select vartype, context, enumvals from sys_settings where name='database_mode'
///|   --> enum | internal | {pg,oracle,mysql,sqlserver,0,1,2,3}
///| ```
///|
///| The context is `internal`, so no session can change it. A client reads it
///| once and adapts.
///|
///| The mode is not the whole story. Three more GUCs change the same behavior
///| across instances, so this package reads them instead of assuming a value per
///| mode:
///| - `enable_ci` -- identifier case handling, fixed at `initdb`.
///| - `ora_input_emptystr_isnull` -- whether an empty string input means NULL.
///| - `quoted_identifier` -- whether double quotes mark an identifier or a
///|   string, on modes that follow SQL Server quoting rules.
///|
///| Every rule carries one of three evidence tags:
///| - `measured`: run on the target instance (`database_mode = sqlserver`),
///|   recorded in `docs/data/mode-probe-sqlserver.txt`.
///| - `pg-compatible`: standard PostgreSQL behavior, which `pg` mode reproduces.
///| - `documented`: taken from the KingbaseES manual for that mode, not run
///|   against a server. Verify with `kingbase_bench probe` before you rely on it.
pub(all) enum Mode {
  Pg
  Oracle
  Mysql
  Sqlserver
} derive(Debug, Eq, Compare, Show)

///| The mode assumed when an instance reports nothing.
///|
/// `pg` is the base every KingbaseES build keeps, because KingbaseES is built on
/// the PostgreSQL kernel, so an unreadable mode is closest to that.
pub fn unknown_mode() -> Mode {
  Pg
}

///|
/// Maps the value of `database_mode` to a `Mode`.
///|
/// The GUC also reports `0` to `3`, so both spellings are accepted.
pub fn mode_of(name : String) -> Mode? {
  match name {
    "pg" | "postgres" | "postgresql" | "0" => Some(Pg)
    "oracle" | "1" => Some(Oracle)
    "mysql" | "2" => Some(Mysql)
    "sqlserver" | "mssql" | "sql_server" | "3" => Some(Sqlserver)
    _ => None
  }
}

///|
/// The short name the server uses for this mode.
pub fn Mode::name(self : Mode) -> String {
  match self {
    Pg => "pg"
    Oracle => "oracle"
    Mysql => "mysql"
    Sqlserver => "sqlserver"
  }
}

///| The setting names a `Dialect` reads.
///|
/// One query asks for all of them. `sqlserver` mode treats a double quote as a
/// string delimiter unless `quoted_identifier` is on, and an apostrophe as an
/// escape, so a name list built with string concatenation can fail to parse on
/// one mode and work on another. The query is therefore written once, as the
/// bracket-quoted form in `sql_in_list`, and this list only names the keys.
/// measured in `docs/data/probe-sqlserver.txt`.
pub fn setting_names() -> Array[String] {
  [
    "database_mode",
    "server_version",
    "enable_ci",
    "ora_input_emptystr_isnull",
    "quoted_identifier",
    "sql_mode",
    "datestyle",
    "dateformat",
    "copy_mode",
    "standard_conforming_strings",
  ]
}

///|
/// The query that reads every name in `setting_names` from one catalog view.
///|
/// The names are single-quoted, which is the form every mode takes; the view
/// name is the caller's choice, because it differs per mode. On another mode the
/// query may fail to parse, and `Client::connect` then falls back to `show` per
/// name, so a mode with no such view still gets its dialect.
pub fn sql_in_list(view : String) -> String {
  // 39 is the apostrophe, written as a code so the MoonBit lexer sees no
  // nested quote.
  let q = quote_code(39)
  let names = setting_names().map(n => q + n + q).join(", ")
  "select name, setting from " + view + " where name in (" + names + ") order by 1"
}

///|
/// The catalog views to try when reading settings, best guess first.
///|
/// measured across all four modes: `pg` mode has no `sys_*` view at all
/// (`sys_settings` answers 42P01) and exposes `pg_settings`; `sqlserver`,
/// `oracle` and `mysql` answer `sys_settings`. The second name is a fallback for
/// a build that reports its mode differently from the catalogs it ships.
pub fn settings_views(mode : Mode) -> Array[String] {
  match mode {
    Pg => ["pg_settings", "sys_settings"]
    Oracle | Mysql | Sqlserver => ["sys_settings", "pg_settings"]
  }
}

///|
/// The name this mode uses for one catalog object, e.g. `class` or `indexes`.
///|
/// measured: pg mode answers `pg_class`, `pg_namespace`, `pg_indexes` and
/// rejects `sys_class` with 42P01; sqlserver mode answers both prefixes, so the
/// `sys_` form serves the other three modes.
pub fn Dialect::catalog_view(self : Dialect, base : String) -> String {
  if self.mode == Pg {
    "pg_" + base
  } else {
    "sys_" + base
  }
}

///|
/// One character as a one-character string.
///|
/// A character literal is a `Char`, and a `Char` cannot be appended to a
/// `String` directly, so an escape is turned into a string first.
///|
/// `unsafe_to_char` is used because every call site passes an ASCII code; the
/// safe `to_char` returns `Char?` and would only add a check that cannot fail.
fn quote_code(code : Int) -> String {
  String::from_array([code.unsafe_to_char()])
}

///|
/// One setting name, folded to lower case for the keys of a `Dialect`.
///|
/// The catalog reports `DateStyle` and `DateFormat` while the client asks for
/// `datestyle` and `dateformat`, so keys must be normalised. Only ASCII letters
/// are folded, because a locale-dependent fold would change per session.
fn fold_key(name : String) -> String {
  let out : Array[Char] = []
  for ch in name.iter() {
    let c = ch.to_int()
    if c >= 65 && c <= 90 {
      out.push((c + 32).unsafe_to_char())
    } else {
      out.push(ch)
    }
  }
  String::from_array(out)
}

///| One SQL term a schema builder needs, mapped to a type name per mode.
pub(all) enum ColumnKind {
  BigInt
  Int32
  Int16
  /// precision and scale
  Decimal(Int, Int)
  /// maximum length
  Varchar(Int)
  /// fixed length
  Char(Int)
  Timestamp
  Boolean
} derive(Debug, Eq, Show)

///| How an unquoted identifier appears in the catalog afterwards.
pub(all) enum CaseFold {
  /// pg-compatible, and documented for `enable_ci = on`
  Lower
  /// documented for Oracle mode
  Upper
  /// measured: `select 1 as Foo` reports the column name `Foo`
  Preserve
} derive(Debug, Eq, Show)

///| The dialect of one connected instance: its mode plus the settings that
///|
/// change the answer.
///|
/// Construct it with `new_dialect`. The values are measured on the
/// live instance in `Client::connect`, so they reflect the target, not a guess
/// about a mode.
pub struct Dialect {
  mode : Mode
  settings : Map[String, String]
} derive(Debug)

///|
/// Reads the settings a `Dialect` needs from rows of `(name, value)`.
pub fn new_dialect(
  rows : Array[(String, String)],
  /// used when the target does not report `database_mode`
  fallback : Mode,
) -> Dialect {
  let m = Map::new()
  for pair in rows {
    let (k, v) = pair
    m[fold_key(k)] = v
  }
  let mode = match m.get("database_mode") {
    Some(s) => match mode_of(s) {
      Some(md) => md
      None => fallback
    }
    None => fallback
  }
  { mode: mode, settings: m }
}

///|
/// The value of one setting, or "" when the instance does not report it.
pub fn Dialect::setting(self : Dialect, key : String) -> String {
  match self.settings.get(key) {
    Some(v) => v
    None => ""
  }
}

///|
/// A `on` / `off` setting, with a default for an instance that lacks it.
pub fn Dialect::flag(self : Dialect, key : String, default : Bool) -> Bool {
  match self.settings.get(key) {
    Some(v) =>
      match v {
        "on" | "true" | "1" | "yes" => true
        "off" | "false" | "0" | "no" => false
        _ => default
      }
    None => default
  }
}

///| Does an empty string input mean NULL?
///|
/// The instance answers this. measured on the target:
/// `ora_input_emptystr_isnull = off`, and an empty `varchar` is not NULL there.
///|
/// documented: the manual for that GUC says `on` makes an empty string NULL to
/// match Oracle, and that `pg` mode needs it `off`. When the GUC is absent, the
/// mode decides.
pub fn Dialect::empty_string_is_null(self : Dialect) -> Bool {
  if self.settings.contains("ora_input_emptystr_isnull") {
    self.flag("ora_input_emptystr_isnull", false)
  } else {
    match self.mode {
      Oracle => true
      _ => false
    }
  }
}

///| How unquoted identifiers are folded.
///|
/// `enable_ci` is read when the instance reports it. documented: case
/// insensitive handling folds names to lower case. measured: this instance
/// reports `enable_ci = on` and keeps the written case in a result column
/// label, so label text is not evidence about the catalog.
pub fn Dialect::case_fold(self : Dialect) -> CaseFold {
  if self.settings.contains("enable_ci") {
    if self.flag("enable_ci", true) {
      Lower
    } else {
      Preserve
    }
  } else {
    match self.mode {
      Pg => Lower
      Oracle => Upper
      Mysql | Sqlserver => Preserve
    }
  }
}

///| Quotes one identifier.
///|
/// measured: on this instance `quoted_identifier = on`, `"Foo"` marks an
/// identifier, `[Foo Bar]` also works, and a backtick is a syntax error
/// (SQLSTATE 42601).
///|
/// When `quoted_identifier` is off, double quotes mark a string on modes that
/// follow SQL Server rules, so brackets are used instead. The manual does not
/// cover bracket acceptance, so `probe` measures it.
pub fn Dialect::quote_ident(self : Dialect, name : String) -> String {
  let use_backtick = match self.mode {
    Mysql => !self.sql_mode_has("ANSI_QUOTES")
    _ => false
  }
  if use_backtick {
    "`\{name}`"
  } else if self.mode == Sqlserver && !self.flag("quoted_identifier", true) {
    "[\{name}]"
  } else {
    "\"\{name}\""
  }
}

///|
/// True when `sql_mode` lists one flag. measured: this instance reports
/// `sql_mode = ONLY_FULL_GROUP_BY,ANSI_QUOTES` even in sqlserver mode.
pub fn Dialect::sql_mode_has(self : Dialect, flag : String) -> Bool {
  let s = self.setting("sql_mode")
  s.split(",").any(part => part.trim() == flag)
}

///| The type name for one column kind.
///|
/// The names below are the ones a schema builder needs. measured for
/// sqlserver mode: `bigint`, `int`, `smallint`, `numeric(18,4)`, `varchar(n)`,
/// `datetime`, and `bit` all cast without error, while `varchar2`, `number` and
/// `nvarchar2` do not exist there (SQLSTATE 42704).
pub fn Dialect::column_type(self : Dialect, kind : ColumnKind) -> String {
  match self.mode {
    // pg-compatible: the PostgreSQL type names.
    Pg =>
      match kind {
        BigInt => "bigint"
        Int32 => "integer"
        Int16 => "smallint"
        Decimal(p, s) => "numeric(\{p},\{s})"
        Varchar(n) => "varchar(\{n})"
        Char(n) => "char(\{n})"
        Timestamp => "timestamp"
        Boolean => "boolean"
      }
    // documented: Oracle has no integer types. `number(p)` carries them, and
    // the manual says `date` stores date and time, so a timestamp column is
    // still the widest choice: `timestamp`.
    // measured here: `varchar2` and `number` are absent on the sqlserver
    // instance, which matches a mode-scoped type set.
    Oracle =>
      match kind {
        BigInt => "number(19)"
        Int32 => "number(10)"
        Int16 => "number(5)"
        Decimal(p, s) => "number(\{p},\{s})"
        Varchar(n) => "varchar2(\{n})"
        Char(n) => "char(\{n})"
        Timestamp => "timestamp"
        Boolean => "number(1)"
      }
    // documented: MySQL type names. `datetime` is used instead of `timestamp`
    // because a MySQL `timestamp` is a 32-bit type with automatic update
    // semantics.
    // measured: the manual calls `boolean` an alias of `tinyint(1)`, but this
    // instance stores a PostgreSQL boolean under that name and prints `t`, so
    // `boolean_text` follows the type name rather than the MySQL rule.
    Mysql =>
      match kind {
        BigInt => "bigint"
        Int32 => "int"
        Int16 => "smallint"
        Decimal(p, s) => "decimal(\{p},\{s})"
        Varchar(n) => "varchar(\{n})"
        Char(n) => "char(\{n})"
        Timestamp => "datetime"
        Boolean => "boolean"
      }
    // measured: SQL Server names on this instance.
    // `datetime` is required for a timestamp column, because a `timestamp`
    // column in this mode is the rowversion type: the cast
    // `select cast('2022-01-01 10:20:30' as timestamp)` returns a column named
    // `rowversion` and the value `0x323032322D30312D`.
    Sqlserver =>
      match kind {
        BigInt => "bigint"
        Int32 => "int"
        Int16 => "smallint"
        Decimal(p, s) => "numeric(\{p},\{s})"
        Varchar(n) => "varchar(\{n})"
        Char(n) => "char(\{n})"
        Timestamp => "datetime"
        Boolean => "bit"
      }
  }
}

///|
/// The type name this mode uses for a date-and-time column.
pub fn Dialect::timestamp_type(self : Dialect) -> String {
  self.column_type(Timestamp)
}

///| The clause that returns `limit` rows starting at `offset`.
///|
/// The modes share no one pagination syntax, so generated SQL asks for a clause
/// instead of writing `limit` in the query text.
/// measured: this sqlserver instance accepts all three of
/// `limit 1 offset 0`, `top 1`, and `offset 0 rows fetch next 1 rows only`.
/// documented: the SQL Server reference says `TOP` cannot combine with `OFFSET`
/// and `FETCH` in one query, so the two forms stay separate here.
pub fn Dialect::limit_clause(self : Dialect, limit : Int, offset : Int) -> String {
  match self.mode {
    // pg-compatible.
    Pg => "limit \{limit} offset \{offset}"
    // documented: Oracle 12c and later accept the standard form.
    Oracle => "offset \{offset} rows fetch next \{limit} rows only"
    // documented: the MySQL reference covers `LIMIT row_count`; the
    // `LIMIT count OFFSET start` spelling is the MySQL form and is marked
    // documented until a mysql-mode run confirms it.
    Mysql => "limit \{limit} offset \{offset}"
    // measured: the standard form works, and it needs no hidden `order by`.
    Sqlserver => "offset \{offset} rows fetch next \{limit} rows only"
  }
}

///| Renders "the first `n` rows" as a clause on the `select` keyword.
///|
/// documented: `TOP` belongs to the SQL Server grammar. The other modes return
/// "" here, and the caller uses `limit_clause` with offset 0 instead.
pub fn Dialect::top_clause(self : Dialect, n : Int) -> String {
  match self.mode {
    // measured: `select top 1 1` returns one row.
    Sqlserver => "top \{n} "
    Pg | Oracle | Mysql => ""
  }
}

///| Renders the concatenation of two expressions.
///|
/// measured: `||` on two `varchar` values fails on this instance with SQLSTATE
/// 42883 ("varchar || varchar" operator does not exist), while `concat()` and
/// `+` both work.
///|
/// pg-compatible: `||` is the standard operator in `pg` mode.
///| documented: the MySQL reference lists `CONCAT`, and in MySQL `||` is a
/// logical operator unless `sql_mode` adds `PIPES_AS_CONCAT`.
pub fn Dialect::concat(self : Dialect, a : String, b : String) -> String {
  let pipes = match self.mode {
    Pg | Oracle => true
    Mysql => self.sql_mode_has("PIPES_AS_CONCAT")
    Sqlserver => false
  }
  if pipes {
    "\{a} || \{b}"
  } else {
    "concat(\{a},\{b})"
  }
}

///| Renders the current timestamp.
///|
/// The expression that returns the current date and time in this mode.
/// measured, one instance per mode: `now()` answers in all four. `sysdate` works
/// only in oracle and mysql mode, and `getdate()` — the SQL Server form this mode
/// is named after — is refused in all four. `current_timestamp` answers in all
/// four too, and prints differently: sqlserver mode gives `now()` an offset
/// (`2026-10-09 12:30:55.458090+08`) but `current_timestamp` none, mysql mode
/// gives neither an offset, and pg mode gives both one. A client therefore reads
/// timestamps as text and never parses them, which is what `ResultSet` does.
pub fn Dialect::now_expression(self : Dialect) -> String {
  match self.mode {
    Pg | Oracle | Mysql | Sqlserver => "now()"
  }
}

///| Can this mode take `COPY ... FROM STDIN` in binary format?
///|
/// measured, one instance per mode: a `PGCOPY` binary image loaded into a session
/// temp table and the value read back was correct in pg, oracle, mysql and
/// sqlserver mode, and `COPY ... TO STDOUT WITH (FORMAT BINARY)` answers the same
/// way. The clause is accepted; an earlier claim here that it returned 42601 came
/// from sending the non-existent option `WITH (BINARY)`.
///|
/// The loader still writes text: its throughput is set by the server's insert
/// path, and text needs no encoder per column type. `probe` re-measures this per
/// instance.
pub fn Dialect::binary_copy_supported(self : Dialect) -> Bool {
  match self.mode {
    Pg | Oracle | Mysql | Sqlserver => true
  }
}

///| Does the mode take the extended query protocol (Parse / Bind / Execute)?
///|
/// measured, one instance per mode: a lone Parse answers SQLSTATE 08P01
/// ("insufficient data left in message") in pg, oracle, mysql and sqlserver mode,
/// whether the messages are framed by this library or by a second, independent
/// implementation, and the session survives it. This is a property of the
/// deployment, not of one compatibility mode.
///|
/// Prepared statements are reachable as SQL over the simple protocol. measured:
/// a parameterised one runs in every mode; a parameterless one runs in pg, oracle
/// and mysql mode, while sqlserver mode reads `execute p` as a stored-procedure
/// call (42883) and `execute p()` as a syntax error (42601).
///|
/// The simple query protocol works in all four modes, so the client uses it and a
/// false value here costs nothing.
pub fn Dialect::extended_protocol_supported(self : Dialect) -> Bool {
  match self.mode {
    Pg | Oracle | Mysql | Sqlserver => false
  }
}

///| Are backslash escapes in a string literal a escape mechanism or a literal?
///|
/// measured: `standard_conforming_strings = on`, and `cast('a\\b' as
/// varchar(10))` keeps the two characters as written.
///| pg-compatible: the same GUC name and meaning.
pub fn Dialect::conforming_strings(self : Dialect) -> Bool {
  self.flag("standard_conforming_strings", true)
}

///| Text the server returns for a timestamp value.
///|
/// measured: this instance prints `2022-01-01 10:20:30.000` with
/// `datestyle = ISO, YMD` and `dateformat = MDY`.
///| documented: Oracle mode formats date text from `nls_date_format`, which
/// this instance does not expose.
pub fn Dialect::timestamp_text_example(self : Dialect) -> String {
  match self.mode {
    Pg => "2022-01-01 10:20:30"
    Oracle => "2022-01-01 10:20:30"
    Mysql => "2022-01-01 10:20:30"
    Sqlserver => "2022-01-01 10:20:30.000"
  }
}

///| Literal text for a boolean value on `COPY`.
///|
/// measured: a `bit` column accepts the text `1`; a boolean cast here prints
/// `t`. The loader sends `1` and `0`, which both spellings take.
///|
/// The text a boolean column takes on input, and the text it prints.
///|
/// This follows the type the mode chooses, not the mode name. measured: with the
/// `bit` column sqlserver mode picks, the value prints as `1`; with `number(1)`
/// oracle mode prints `1`; with a `boolean` column both pg mode and mysql mode
/// print `t`, which surprised us in mysql mode, where MySQL's own boolean is a
/// `tinyint(1)` that prints `1`. KingbaseES keeps the PostgreSQL boolean there,
/// and its text form is `t`/`f`.
///|
/// Writing `1` into a PostgreSQL boolean is accepted as true, so an old loader
/// that sent numeric text still worked; reading it back did not match the text it
/// had sent. Spelling the value the way the column spells it is what makes a
/// round trip check possible.
pub fn Dialect::boolean_text(self : Dialect, value : Bool) -> String {
  if self.column_type(Boolean) == "boolean" {
    if value { "t" } else { "f" }
  } else {
    if value { "1" } else { "0" }
  }
}

///| Query that reads one setting, in a form all four modes take.
///|
/// measured: `select current_setting('database_mode')` and
/// `show database_mode` both work here.
pub fn Dialect::setting_query(key : String) -> String {
  "select current_setting('\{key}')"
}

///|
/// `sum` over an integer column, widened so the total cannot wrap.
///|
/// measured on one instance per mode, over the same 1,000,000 deterministic rows:
/// sqlserver mode answers `pg_typeof(sum(cust_id)) = int` and reports
/// 1335346292, while pg and mysql mode answer `bigint` and oracle mode `numeric`,
/// all three reporting 9925280884. The two numbers differ by exactly 2^33, so
/// sqlserver mode wrapped the total silently instead of raising. Casting the
/// column first gives 9925280884 in every mode.
///|
/// An aggregate checksum taken in one mode therefore does not equal the same
/// checksum taken in another, which matters when a benchmark result is compared
/// across instances.
pub fn Dialect::wide_sum(self : Dialect, column : String) -> String {
  match self.mode {
    Sqlserver => "sum(cast(\{column} as bigint))"
    Pg | Oracle | Mysql => "sum(\{column})"
  }
}

///| Query that lists the indexes of one table.
///|
/// measured: `sys_indexes` returns the five index names of the benchmark table in
/// sqlserver, oracle and mysql mode; pg mode has no `sys_` view and answers
/// `pg_indexes` instead, so the view name comes from `catalog_view`.
pub fn Dialect::index_list_query(self : Dialect, table : String) -> String {
  let view = self.catalog_view("indexes")
  "select indexname from \{view} where tablename=\{sql_literal(table)} order by 1"
}

///| One value as a SQL string literal.
///|
/// measured: a value compared with a catalog column is written in single quotes
/// in every mode of this instance, while an identifier is written in double
/// quotes or brackets. Quoting the wrong kind is a 42703 "column does not
/// exist", not a type error, so the two must stay separate calls.
///|
/// An apostrophe inside the value is doubled, which is the standard escape and
/// needs no backslash, so the literal is safe whatever `standard_conforming_strings`
/// says.
pub fn sql_literal(value : String) -> String {
  let q = quote_code(39)
  q + value.replace(old=q, new=q + q) + q
}

///| Offline tests for the dialect layer.
///|
///| These need no server. They pin the rules a schema builder and a query
///| generator rely on, so a change to one mode cannot silently alter another.
///| The values marked measured in `dialect.mbt` come from the sqlserver
///| instance's probe archives, `docs/data/probe-sqlserver.txt` and
///| `docs/data/mode-probe-sqlserver.txt` in the KingBase-Test repository; the
///| `probe` command there regenerates the first one against any instance.
fn dialect_with(mode : String, extra : Array[(String, String)]) -> Dialect {
  let rows = [("database_mode", mode)] + extra
  new_dialect(rows, Pg)
}

///|
test "mode names and enum labels map" {
  assert_eq(mode_of("sqlserver"), Some(Sqlserver))
  assert_eq(mode_of("pg"), Some(Pg))
  assert_eq(mode_of("oracle"), Some(Oracle))
  assert_eq(mode_of("mysql"), Some(Mysql))
  // sys_settings reports the same enum as digits.
  assert_eq(mode_of("3"), Some(Sqlserver))
  assert_eq(mode_of("access"), None)
}

///|
test "mode maps every column kind in its own family" {
  let pg = dialect_with("pg", [])
  let ora = dialect_with("oracle", [])
  let my = dialect_with("mysql", [])
  let ss = dialect_with("sqlserver", [])
  inspect(pg.column_type(BigInt), content="bigint")
  inspect(pg.column_type(Int32), content="integer")
  inspect(pg.column_type(Decimal(18, 4)), content="numeric(18,4)")
  inspect(pg.timestamp_type(), content="timestamp")
  inspect(pg.column_type(Boolean), content="boolean")
  // measured: number and varchar2 do not exist in sqlserver mode, so they
  // belong to the oracle family only.
  inspect(ora.column_type(Int32), content="number(10)")
  inspect(ora.column_type(Varchar(64)), content="varchar2(64)")
  inspect(ora.column_type(BigInt), content="number(19)")
  inspect(my.column_type(Timestamp), content="datetime")
  inspect(my.column_type(Decimal(18, 4)), content="decimal(18,4)")
  // measured: a sqlserver-mode timestamp column must be datetime, because
  // timestamp there is the rowversion type.
  inspect(ss.timestamp_type(), content="datetime")
  inspect(ss.column_type(Varchar(32)), content="varchar(32)")
  inspect(ss.column_type(Boolean), content="bit")
}

///|
test "pagination renders one clause per family" {
  let pg = dialect_with("pg", [])
  let ss = dialect_with("sqlserver", [])
  inspect(pg.limit_clause(100, 500), content="limit 100 offset 500")
  inspect(ss.limit_clause(100, 500), content="offset 500 rows fetch next 100 rows only")
  inspect(dialect_with("oracle", []).limit_clause(1, 0), content="offset 0 rows fetch next 1 rows only")
  inspect(dialect_with("mysql", []).limit_clause(10, 20), content="limit 10 offset 20")
  // measured: TOP is the sqlserver family only.
  inspect(ss.top_clause(10), content="top 10 ")
  inspect(pg.top_clause(10), content="")
}

///|
test "concatenation follows the family and sql_mode" {
  let pg = dialect_with("pg", [])
  // measured: || on varchar fails in sqlserver mode, concat works.
  let ss = dialect_with("sqlserver", [])
  inspect(pg.concat("a", "b"), content="a || b")
  inspect(ss.concat("a", "b"), content="concat(a,b)")
  let my = dialect_with("mysql", [("sql_mode", "ONLY_FULL_GROUP_BY")])
  inspect(my.concat("a", "b"), content="concat(a,b)")
  let pipe = dialect_with("mysql", [("sql_mode", "PIPES_AS_CONCAT")])
  inspect(pipe.concat("a", "b"), content="a || b")
}

///|
test "identifier quoting reads quoted_identifier and sql_mode" {
  // measured: on the target quoted_identifier is on and a backtick is a
  // syntax error, so double quotes are used.
  let ss = dialect_with("sqlserver", [("quoted_identifier", "on")])
  inspect(ss.quote_ident("orders"), content="\"orders\"")
  let ss_off = dialect_with("sqlserver", [("quoted_identifier", "off")])
  inspect(ss_off.quote_ident("orders"), content="[orders]")
  let my = dialect_with("mysql", [("sql_mode", "ONLY_FULL_GROUP_BY")])
  inspect(my.quote_ident("orders"), content="`orders`")
  // measured: this instance reports ANSI_QUOTES inside sql_mode.
  let my_aq = dialect_with("mysql", [("sql_mode", "ONLY_FULL_GROUP_BY,ANSI_QUOTES")])
  inspect(my_aq.quote_ident("orders"), content="\"orders\"")
}

///|
test "empty string semantics prefer the GUC over the mode" {
  // measured: the target reports the GUC off, and an empty varchar is not NULL.
  let ss = dialect_with("sqlserver", [("ora_input_emptystr_isnull", "off")])
  assert_eq(ss.empty_string_is_null(), false)
  let ora_guc_on = dialect_with("oracle", [("ora_input_emptystr_isnull", "on")])
  assert_eq(ora_guc_on.empty_string_is_null(), true)
  // An instance that does not report the GUC falls back to the mode rule.
  assert_eq(dialect_with("oracle", []).empty_string_is_null(), true)
  assert_eq(dialect_with("pg", []).empty_string_is_null(), false)
}

///|
test "case fold reads enable_ci" {
  // measured: the target reports enable_ci = on.
  assert_eq(dialect_with("sqlserver", [("enable_ci", "on")]).case_fold(), Lower)
  assert_eq(dialect_with("sqlserver", [("enable_ci", "off")]).case_fold(), Preserve)
  assert_eq(dialect_with("oracle", []).case_fold(), Upper)
}

///|
test "boolean text follows the column type, not the mode name" {
  // measured on each instance, by loading a row and reading the value back:
  // sqlserver `bit` -> 1, oracle `number(1)` -> 1, pg `boolean` -> t, and mysql
  // `boolean` -> t as well, although MySQL itself spells its boolean 1.
  inspect(dialect_with("sqlserver", []).boolean_text(true), content="1")
  inspect(dialect_with("oracle", []).boolean_text(false), content="0")
  inspect(dialect_with("mysql", []).boolean_text(false), content="f")
  inspect(dialect_with("mysql", []).boolean_text(true), content="t")
  inspect(dialect_with("pg", []).boolean_text(true), content="t")
}

///|
test "unknown mode falls back without failing" {
  // A build that does not report database_mode keeps the caller's fallback.
  let d = new_dialect([("datestyle", "ISO, MDY")], Sqlserver)
  assert_eq(d.mode, Sqlserver)
  inspect(d.setting("datestyle"), content="ISO, MDY")
  inspect(d.setting("absent"), content="")
  // An unrecognized mode text also keeps the fallback.
  let e = dialect_with("access", [])
  assert_eq(e.mode, Pg)
}

///|
test "flags default when a setting is absent" {
  let d = dialect_with("sqlserver", [])
  assert_eq(d.flag("standard_conforming_strings", true), true)
  assert_eq(d.flag("standard_conforming_strings", false), false)
  let off = dialect_with("sqlserver", [("standard_conforming_strings", "off")])
  assert_eq(off.flag("standard_conforming_strings", true), false)
  // A non-boolean value keeps the caller's default instead of guessing.
  let odd = dialect_with("sqlserver", [("copy_mode", "kes")])
  assert_eq(odd.flag("copy_mode", true), true)
  inspect(odd.setting("copy_mode"), content="kes")
}

///|
test "measured capabilities per mode" {
  let ss = dialect_with("sqlserver", [])
  // measured, one instance per mode: a PG binary COPY image loaded into a session
  // temp table and the value read back was correct in all four.
  assert_eq(ss.binary_copy_supported(), true)
  assert_eq(dialect_with("pg", []).binary_copy_supported(), true)
  assert_eq(dialect_with("oracle", []).binary_copy_supported(), true)
  assert_eq(dialect_with("mysql", []).binary_copy_supported(), true)
  // measured, one instance per mode: a lone Parse answers 08P01 everywhere, from
  // this library and from an independent implementation alike.
  assert_eq(ss.extended_protocol_supported(), false)
  assert_eq(dialect_with("pg", []).extended_protocol_supported(), false)
  // measured: now() answers in all four modes; getdate() answers in none.
  for mode in ["pg", "oracle", "mysql", "sqlserver"] {
    inspect(dialect_with(mode, []).now_expression(), content="now()")
  }
}

///|
test "an integer sum is widened where the mode would wrap it" {
  // measured, one instance per mode, same 1,000,000 rows: sqlserver answers
  // 1335346292 (a wrapped int) while pg, oracle and mysql answer 9925280884.
  inspect(
    dialect_with("sqlserver", []).wide_sum("cust_id"),
    content="sum(cast(cust_id as bigint))",
  )
  inspect(dialect_with("pg", []).wide_sum("cust_id"), content="sum(cust_id)")
  inspect(
    dialect_with("oracle", []).wide_sum("cust_id"),
    content="sum(cust_id)",
  )
  inspect(
    dialect_with("mysql", []).wide_sum("cust_id"),
    content="sum(cust_id)",
  )
}

///|
test "a value is a literal and a catalog view follows the mode" {
  // measured: single quotes in every form here, and an apostrophe doubles.
  inspect(sql_literal("abc"), content="'abc'")
  inspect(sql_literal("it's"), content="'it''s'")
  // The catalog name goes through sql_literal, because quoting it as an
  // identifier gives 42703 on this instance.
  // The catalog view is the other half: pg mode has no sys_ view at all
  // (measured: 42P01 on sys_settings, sys_class, sys_indexes).
  let ss = dialect_with("sqlserver", [])
  assert_eq(
    ss.index_list_query("mb_orders"),
    "select indexname from sys_indexes where tablename='mb_orders' order by 1",
  )
  let pg = dialect_with("pg", [])
  assert_eq(
    pg.index_list_query("mb_orders"),
    "select indexname from pg_indexes where tablename='mb_orders' order by 1",
  )
  assert_eq(ss.catalog_view("class"), "sys_class")
  assert_eq(pg.catalog_view("class"), "pg_class")
  assert_eq(settings_views(Pg)[0], "pg_settings")
  assert_eq(settings_views(Sqlserver)[0], "sys_settings")
}

///|
/// Offline tests for the command-tag reader. A DML check compares against these
/// tags, so their parsing must not depend on a server.
fn rows_of(tag : String) -> Int {
  let set : ResultSet = { columns: [], rows: [], command: tag }
  set.affected()
}

///|
test "affected reads the trailing number of a command tag" {
  // measured shapes on these instances.
  assert_eq(rows_of("INSERT 0 1"), 1)
  assert_eq(rows_of("INSERT 0 12"), 12)
  assert_eq(rows_of("UPDATE 3"), 3)
  assert_eq(rows_of("DELETE 1000"), 1000)
  assert_eq(rows_of("COPY 5000"), 5000)
  assert_eq(rows_of("SELECT 1"), 1)
}

///|
test "affected reports zero when the tag carries no count" {
  assert_eq(rows_of("SHOW"), 0)
  assert_eq(rows_of(""), 0)
  assert_eq(rows_of("SET "), 0)
  assert_eq(rows_of("DELETE 0"), 0)
}

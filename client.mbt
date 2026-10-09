///| KingbaseES client: PostgreSQL wire protocol 3.0, simple query, text COPY.
///|
///| Blocking sockets, no async runtime. Failures raise, and the SQLSTATE code of
///|
/// a server error stays in the message text.
///|
///| ## What the mode does not decide
///|
///| `database_mode` fixes the dialect family, and three more settings change the
///| answer inside one family. `connect` reads them once, so the rest of a program
///| asks a `Dialect` instead of testing the mode:
///|
///| ```moonbit
///| let client = @kb.connect(@kb.new_config(
///|   "10.19.1.156", 54321, "test", "secret", "test",
///| ))
///| println(client.mode().name())               // "sqlserver" on the target
///| println(client.dialect().timestamp_type())  // "datetime" there, "timestamp" in pg
///| ```
pub using @dialect {
  mode_of, type Mode, type Dialect, type ColumnKind, type CaseFold,
}

pub struct Config {
  host : String
  port : Int
  user : String
  password : String
  database : String
  ///| Read `database_mode` and the settings that refine it after
  /// authentication. One extra query per connection.
  detect_dialect : Bool
  ///| Used when detection is off, or when the instance does not report the mode.
  fallback_mode : Mode?
} derive(Debug)

///|
/// A configuration that detects the dialect of the target.
pub fn new_config(
  host : String,
  port : Int,
  user : String,
  password : String,
  database : String,
) -> Config {
  {
    host,
    port,
    user,
    password,
    database,
    detect_dialect: true,
    fallback_mode: None,
  }
}

///|
/// A configuration that skips the detection query, for a connection used once by
/// a program that already knows the mode.
pub fn new_config_fixed_mode(
  host : String,
  port : Int,
  user : String,
  password : String,
  database : String,
  mode : Mode,
) -> Config {
  {
    host,
    port,
    user,
    password,
    database,
    detect_dialect: false,
    fallback_mode: Some(mode),
  }
}

pub(all) struct ServerError {
  severity : String
  code : String
  message : String
} derive(Debug, Eq, Show)

pub fn ServerError::describe(self : ServerError) -> String {
  "[\{self.code}] \{self.severity}: \{self.message}"
}

///|
/// One result set: column names and text-format values (`None` = SQL NULL).
///|
/// Every value is the server's own text output. The client parses no type, so a
/// mode that prints a timestamp differently cannot break a read.
pub struct ResultSet {
  columns : Array[String]
  rows : Array[Array[String?]]
  command : String
} derive(Debug)

pub fn ResultSet::row_count(self : ResultSet) -> Int {
  self.rows.length()
}

pub fn ResultSet::column_count(self : ResultSet) -> Int {
  self.columns.length()
}

pub fn ResultSet::cell(self : ResultSet, row : Int, col : Int) -> String {
  match self.rows.get(row) {
    Some(r) =>
      match r.get(col) {
        Some(Some(s)) => s
        _ => "NULL"
      }
    None => ""
  }
}

pub fn ResultSet::first_text(self : ResultSet, col : Int) -> String {
  self.cell(0, col)
}

///|
/// The first column of the first row, or "" when the set is empty.
pub fn ResultSet::scalar(self : ResultSet) -> String {
  if self.rows.length() == 0 {
    ""
  } else {
    self.cell(0, 0)
  }
}

///|
/// Rows as `(first column, second column)` pairs, for setting and catalog reads.
pub fn ResultSet::pairs(self : ResultSet) -> Array[(String, String)] {
  let out : Array[(String, String)] = []
  for r in self.rows {
    match r.get(0) {
      Some(Some(k)) => {
        let v = match r.get(1) {
          Some(Some(s)) => s
          _ => ""
        }
        out.push((k, v))
      }
      _ => ()
    }
  }
  out
}

pub struct Client {
  sock : @sys.Socket
  cfg : Config
  params : Map[String, String]
  mut backend_pid : Int
  mut transaction_status : Byte
  mut dialect : Dialect
}

///|
/// Turns an IO error into a raised message with its context.
fn[T] unwrap(r : Result[T, @sys.IOError], context : String) -> T raise {
  match r {
    Ok(v) => v
    Err(e) => fail("\{context}: \{e}")
  }
}

fn send_raw(c : Client, data : Bytes, context : String) -> Unit raise {
  let _ = unwrap(c.sock.write(data), context)
}

fn send_message(
  c : Client,
  tag : Byte,
  body : Bytes,
  context : String,
) -> Unit raise {
  send_raw(c, @wire.header(tag, body.length()), context)
  send_raw(c, body, context)
}

fn read_message(c : Client) -> @sys.Message raise {
  unwrap(c.sock.read_message(), "read")
}

///|
/// Text up to the next NUL: error fields, command tags, column names.
fn text_at(body : Bytes, offset : Int) -> String {
  @sys.text_at(body, offset)
}

///|
/// SCRAM payloads contain no embedded NUL, so they run to the end of the body.
fn text_to_end(body : Bytes, offset : Int) -> String {
  @sys.text_slice(body, offset, body.length() - offset)
}

fn server_error_from(body : Bytes) -> ServerError {
  // ErrorReport is a sequence of <field byte><text><NUL> records terminated by
  // an empty record; severity, SQLSTATE and message are enough for reporting.
  let n = body.length()
  let mut i = 0
  let mut severity = ""
  let mut code = ""
  let mut message = ""
  while i < n {
    let field = body[i]
    if field == b'\x00' {
      break
    }
    let text = text_at(body, i + 1)
    if field == b'S' && severity == "" {
      severity = text
    } else if field == b'C' {
      code = text
    } else if field == b'M' {
      message = if message == "" { text } else { message + " " + text }
    }
    i = i + 1 + text.length() + 1
  }
  { severity, code, message }
}

///|
/// Raises immediately when the message is an ErrorResponse.
fn expect_ok(m : @sys.Message) -> @sys.Message raise {
  if m.tag == b'E' {
    fail(server_error_from(m.body).describe())
  }
  m
}

///|
/// Consumes ParameterStatus / BackendKeyData until ReadyForQuery.
fn pump(c : Client) -> Unit raise {
  while true {
    let m = read_message(c)
    if m.tag == b'S' {
      let k = text_at(m.body, 0)
      c.params[k] = text_at(m.body, k.length() + 1)
    } else if m.tag == b'K' {
      c.backend_pid = @sys.be32(m.body, 0)
    } else if m.tag == b'E' {
      fail(server_error_from(m.body).describe())
    } else if m.tag == b'Z' {
      c.transaction_status = m.body[0]
      return
    }
  } nobreak {
    fail("unreachable")
  }
}

///| Connects, negotiates SSL, sends the startup packet, completes
///| authentication, then reads the dialect of the target.
///|
///| This KingbaseES answers `N` to SSLRequest and stays plaintext. A server that
///| answers `S` is refused rather than continued in plaintext, because a silent
///| downgrade would be invisible to the caller.
pub fn connect(cfg : Config) -> Client raise {
  let sock = unwrap(@sys.connect(cfg.host, cfg.port), "connect")
  let start_mode = match cfg.fallback_mode {
    Some(m) => m
    None => @dialect.unknown_mode()
  }
  let c : Client = {
    sock,
    cfg,
    params: Map::new(),
    backend_pid: 0,
    transaction_status: b'I',
    dialect: @dialect.new_dialect([], start_mode),
  }
  let w = @wire.new_writer(8)
  w.int32(8)
  w.int32(80877103)
  send_raw(c, w.payload(), "ssl request")
  let reply = unwrap(c.sock.read_byte(), "ssl reply")
  if reply != b'N' {
    fail(
      "server answered '\\{reply.to_char()}' to SSLRequest but this client is plaintext-only",
    )
  }
  startup(c)
  authenticate(c)
  pump(c)
  if cfg.detect_dialect {
    read_dialect(c, start_mode)
  }
  c
}

///|
/// Reads the settings that fix the dialect.
///|
/// Three stages, cheapest first, and each keeps whatever the previous one
/// missed: the mode alone, because every later query is shaped by it; one
/// catalog query for all names; then `show` for each name still missing.
///|
/// measured across all four modes: the `pg` mode ships no `sys_*` view at all
/// (`sys_settings` answers 42P01) and exposes `pg_settings`, while the other
/// three answer `sys_settings`. `sql_mode` and `ora_input_emptystr_isnull` are
/// hidden from the view wherever it exists. `quoted_identifier` does not exist in
/// `pg` mode and `DateFormat` not in `pg` or `mysql`, so one combined
/// `current_setting` list fails as a whole on a single undefined name — that is
/// why the last stage asks one name at a time. Reading all ten names separately
/// costs ten round trips of about a millisecond, and only on a mode with no view.
fn read_dialect(c : Client, fallback : Mode) -> Unit {
  let detected = read_mode(c)
  let mode = match detected {
    Some(m) => m
    None => fallback
  }
  let rows = collect_settings(c, mode)
  c.dialect = @dialect.new_dialect(rows, mode)
}

///| The mode, as one setting. `show` answers it where `current_setting` does not.
fn read_mode(c : Client) -> Mode? {
  let attempts : Array[String] = [
    "select current_setting('database_mode')",
    "show database_mode",
  ]
  let mut found : Mode? = None
  for sql in attempts {
    match found {
      Some(_) => ()
      None =>
        match c.try_query(sql) {
          Ok(rs) => found = @dialect.mode_of(rs.scalar())
          Err(_) => ()
        }
    }
  }
  found
}

fn collect_settings(
  c : Client,
  mode : Mode,
) -> Array[(String, String)] {
  let names = @dialect.setting_names()
  let mut rows : Array[(String, String)] = []
  for view in @dialect.settings_views(mode) {
    if rows.length() > 0 {
      break
    }
    match c.try_query(@dialect.sql_in_list(view)) {
      Ok(rs) => rows = rs.pairs()
      Err(_) => ()
    }
  }
  let have = Map::new()
  for pair in rows {
    let (k, _) = pair
    have[k] = "seen"
  }
  for n in names {
    match have.get(n) {
      Some(_) => ()
      None => {
        let v = read_setting(c, n)
        if v != "" {
          rows.push((n, v))
        }
      }
    }
  }
  rows
}

///|
/// One setting through `show`, or an empty string when this mode has no such
/// setting.
fn read_setting(c : Client, name : String) -> String {
  match c.try_query("show " + name) {
    Ok(rs) => rs.scalar()
    Err(_) => ""
  }
}

fn startup(c : Client) -> Unit raise {
  let w = @wire.new_writer(96)
  w.int32(196608) // protocol version 3.0
  w.cstring("user")
  w.cstring(c.cfg.user)
  w.cstring("database")
  w.cstring(c.cfg.database)
  w.cstring("client_encoding")
  w.cstring("UTF8")
  w.byte(b'\x00')
  let body = w.payload()
  // StartupMessage carries no tag byte; its length prefix covers itself plus the
  // version word and every parameter.
  let len = @wire.new_writer(4)
  len.int32(body.length() + 4)
  send_raw(c, len.payload(), "startup length")
  send_raw(c, body, "startup")
}

fn authenticate(c : Client) -> Unit raise {
  while true {
    let m = expect_ok(read_message(c))
    if m.tag != b'R' {
      continue
    }
    let code = @sys.be32(m.body, 0)
    if code == 0 {
      return
    } else if code == 10 {
      sasl(c, m)
      return
    } else if code == 2 {
      // AuthenticationCleartextPassword
      let w = @wire.new_writer(c.cfg.password.length() + 8)
      w.text(c.cfg.password)
      w.byte(b'\x00')
      send_message(c, b'p', w.payload(), "password")
    } else {
      fail(
        "unsupported auth method \{code}; this client implements SCRAM-SHA-256 and cleartext",
      )
    }
  } nobreak {
    fail("unreachable")
  }
}

fn sasl(c : Client, first_msg : @sys.Message) -> Unit raise {
  let mech = text_at(first_msg.body, 4)
  if mech != "SCRAM-SHA-256" {
    fail(
      "server offered SASL mechanism '\{mech}', only SCRAM-SHA-256 is supported",
    )
  }
  let state = scram_client_first(18)
  send_message(
    c,
    b'p',
    scram_initial_response(state.client_first),
    "sasl initial",
  )
  let cont = expect_ok(read_message(c))
  if cont.tag != b'R' || @sys.be32(cont.body, 0) != 11 {
    fail("expected SASLContinue")
  }
  let server_first = text_to_end(cont.body, 4)
  let reply = match scram_respond(state, server_first, c.cfg.password) {
    Ok(r) => r
    Err(e) => fail("scram: \{e}")
  }
  // SASLResponse carries raw SCRAM text: no NUL terminator (the server rejects
  // one as a malformed message).
  let w = @wire.new_writer(reply.client_final.length() + 8)
  w.text(reply.client_final)
  send_message(c, b'p', w.payload(), "sasl response")
  while true {
    let m = expect_ok(read_message(c))
    if m.tag == b'R' {
      let code = @sys.be32(m.body, 0)
      if code == 12 {
        let final_text = text_to_end(m.body, 4)
        if !final_text.has_prefix(scram_expected_server_final(reply)) {
          fail("server signature mismatch")
        }
      } else if code == 0 {
        return
      } else {
        fail("unexpected SASL message code \{code}")
      }
    } else if m.tag == b'Z' {
      return
    }
  } nobreak {
    fail("unreachable")
  }
}

///|
/// Sends a simple query and collects rows until ReadyForQuery.
///|
/// The simple protocol is the only form this client sends, because the target
/// rejects Parse and Bind with SQLSTATE 08P01. A mode that takes the extended
/// protocol reports it through `Dialect::extended_protocol_supported`.
pub fn Client::query(self : Client, sql : String) -> ResultSet raise {
  let w = @wire.new_writer(sql.length() + 8)
  w.cstring(sql)
  send_message(self, b'Q', w.payload(), "query")
  collect(self)
}

///|
/// Runs a statement, discards its rows and returns the command tag.
pub fn Client::execute(self : Client, sql : String) -> String raise {
  self.query(sql).command
}

///|
/// Runs a query and returns its rows, or the server error.
///|
/// A capability probe needs a result for every attempt, so one refusal must not
/// end the run. `query` raises the `describe` text of a `ServerError`, which
/// keeps the SQLSTATE in the leading brackets, so read it back from there.
pub fn Client::try_query(
  self : Client,
  sql : String,
) -> Result[ResultSet, ServerError] {
  let mut err : ServerError? = None
  let mut out : ResultSet? = None
  try self.query(sql) catch {
    @builtin.Failure(msg) => err = Some(error_from_text(msg))
    _ => err = Some({ severity: "", code: "", message: "unexpected failure" })
  } noraise {
    rs => out = Some(rs)
  }
  match err {
    Some(e) => Err(e)
    None =>
      match out {
        Some(rs) => Ok(rs)
        None => Err({ severity: "", code: "", message: "no result" })
      }
  }
}

///|
/// Runs a statement and returns its command tag, or the server error.
pub fn Client::try_execute(self : Client, sql : String) -> Result[String, ServerError] {
  match self.try_query(sql) {
    Ok(rs) => Ok(rs.command)
    Err(e) => Err(e)
  }
}

fn error_from_text(msg : String) -> ServerError {
  // A raised `Failure` text starts with the source location of the `fail` call,
  // then the describe form "[SQLSTATE] SEVERITY: text". The code is searched
  // for, because the location part varies between call sites.
  match msg.find("[") {
    Some(i) if i + 7 <= msg.length() => {
      let code = msg[i + 1:i + 6].to_string()
      let rest = msg[i + 7:].to_string()
      { severity: "", code: code, message: rest }
    }
    _ => { severity: "", code: "", message: msg }
  }
}

///|
/// Sends one statement through the extended query protocol and reports what came
/// back.
///|
/// Parse, Bind, Describe, Execute and Sync go out as one batch, the way a driver
/// that supports prepared statements sends them. The success value is the sequence
/// of message tags the server sent before ReadyForQuery, so a refusal is visible
/// as its SQLSTATE instead of an empty result.
///|
/// This is a capability probe. The client itself runs statements through the simple
/// protocol, because that path needs one message per query and works on every mode
/// measured here.
pub fn Client::extended_try(
  self : Client,
  sql : String,
) -> Result[String, ServerError] raise {
  let parse = @wire.new_writer(sql.length() + 8)
  parse.cstring(sql)
  parse.int16(0) // no parameter type OIDs
  send_message(self, b'P', parse.payload(), "parse")
  let bind = @wire.new_writer(16)
  bind.cstring("") // unnamed portal
  bind.cstring("") // the statement Parse just defined
  bind.int16(0) // no parameter format codes
  bind.int16(0) // no parameter values
  bind.int16(0) // no result format codes, so every column is text
  send_message(self, b'B', bind.payload(), "bind")
  let describe = @wire.new_writer(8)
  describe.byte(b'S') // describe the prepared statement
  describe.cstring("")
  send_message(self, b'D', describe.payload(), "describe")
  let execute = @wire.new_writer(8)
  execute.cstring("") // run the unnamed portal
  execute.int32(0) // no row limit
  send_message(self, b'E', execute.payload(), "execute")
  send_message(self, b'S', @wire.new_writer(4).payload(), "sync")
  read_extended_reply(self)
}

///|
/// Reads replies up to ReadyForQuery. The first ErrorResponse, if any, becomes the
/// failure; otherwise the tags seen so far are returned.
fn read_extended_reply(c : Client) -> Result[String, ServerError] raise {
  let tags = @buffer.new(size_hint=32)
  let mut err : ServerError? = None
  while true {
    let m = read_message(c)
    if m.tag == b'Z' {
      c.transaction_status = m.body[0]
      let text = @sys.buffer_text(tags)
      return match err {
        Some(e) => Err(e)
        None => Ok(text)
      }
    }
    if m.tag == b'E' {
      match err {
        None => err = Some(server_error_from(m.body))
        _ => ()
      }
    }
    // Message tags are ASCII, so the byte is the text.
    tags.write_byte(m.tag)
  }
  nobreak {
    fail("unreachable")
  }
}

///|
/// Reads messages until ReadyForQuery, discarding them.
///|
/// Used after an ErrorResponse, so a caller that catches the failure can keep
/// using the same connection instead of reading the tail of the refused
/// response as the next result.
fn drain_to_ready(c : Client) -> Unit raise {
  while true {
    let m = read_message(c)
    if m.tag == b'Z' {
      c.transaction_status = m.body[0]
      return
    }
  } nobreak {
    fail("unreachable")
  }
}

fn collect(c : Client) -> ResultSet raise {
  let columns : Array[String] = []
  let rows : Array[Array[String?]] = []
  let mut command = ""
  while true {
    let m = read_message(c)
    if m.tag == b'T' {
      columns.clear()
      let n = @sys.be16(m.body, 0)
      let mut off = 2
      let mut i = 0
      while i < n {
        let name = text_at(m.body, off)
        columns.push(name)
        // name + NUL, then table OID(4) + column id(2) + type OID(4) +
        // typlen(2) + typmod(4) + format code(2) = 18 bytes of metadata
        off = off + name.length() + 1 + 18
        i = i + 1
      }
    } else if m.tag == b'D' {
      let n = @sys.be16(m.body, 0)
      let mut off = 2
      let row : Array[String?] = []
      let mut i = 0
      while i < n {
        let len = @sys.be32(m.body, off)
        off = off + 4
        if len < 0 {
          row.push(None)
        } else {
          row.push(Some(@sys.text_slice(m.body, off, len)))
          off = off + len
        }
        i = i + 1
      }
      rows.push(row)
    } else if m.tag == b'C' {
      command = text_at(m.body, 0)
    } else if m.tag == b'E' {
      // The server sends ReadyForQuery after the error. Read to it before
      // raising, or the next statement on this connection would read the tail
      // of this response and return the row count of the statement before it.
      // measured: without this drain, one refused statement shifted every
      // later result by one query.
      let e = server_error_from(m.body)
      drain_to_ready(c)
      fail(e.describe())
    } else if m.tag == b'Z' {
      c.transaction_status = m.body[0]
      let rs : ResultSet = { columns, rows, command }
      return rs
    }
  } nobreak {
    fail("unreachable")
  }
}

///|
/// The dialect of the connected instance.
pub fn Client::dialect(self : Client) -> Dialect {
  self.dialect
}

///|
/// The compatibility mode of the connected instance.
pub fn Client::mode(self : Client) -> Mode {
  self.dialect.mode
}

///|
/// A `ParameterStatus` value the backend sent, e.g. `server_version`.
pub fn Client::setting(self : Client, key : String) -> String {
  match self.params.get(key) {
    Some(v) => v
    None => ""
  }
}

///|
/// `I` when the backend is idle, `T` inside a transaction, `E` after a failure.
pub fn Client::status_byte(self : Client) -> Byte {
  self.transaction_status
}

///|
/// The process id from `BackendKeyData`.
pub fn Client::pid(self : Client) -> Int {
  self.backend_pid
}

///|
/// Sends the terminate message and closes the socket.
pub fn Client::close(self : Client) -> Unit {
  let _ = self.sock.write(@wire.header(b'X', 0))
  self.sock.close()
}

///|
/// Monotonic microseconds, for timing queries and batches.
///|
/// This is the only clock a caller should use for timings: it does not move when
/// the wall clock is corrected.
pub fn now_us() -> Int64 {
  @sys.now_us()
}

///|
/// Text of everything written into a buffer, decoded as UTF-8.
///|
/// `Buffer::to_string` reinterprets bytes as code units on the native target, so
/// report and log text must decode explicitly.
pub fn buffer_text(buf : @buffer.Buffer) -> String {
  @sys.buffer_text(buf)
}

///|
/// Waits for `ms` milliseconds, e.g. between COPY rounds in a paced load.
pub fn sleep_ms(ms : Int) -> Unit {
  @sys.sleep_ms(ms)
}

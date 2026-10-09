///| Server-side `COPY FROM STDIN`, used for bulk loading.
///|
///| ## Formats
///|
///| The text format is what the loader uses: tab-separated fields, one row per
///| line, NULL as `\N`, and backslash, tab and newline escaped with a leading
///| backslash. Binary is sent as opaque bytes, so `CopyStream::send_data` takes
///| any payload and a caller composes the `PGCOPY` image itself.
///|
///| measured: on the sqlserver instance a binary stream loads and reads back
///| correctly, so `Dialect::binary_copy_supported` reports where a target has
///| been shown to take one. Text needs no such check and works in every mode.
///|
///| ## Text fields and the mode
///|
///| Escaping follows the server's own text-COPY rules, which are the same in all
///| four modes. Two mode settings still change what a loaded value becomes:
///| - `Dialect::empty_string_is_null`: an empty field is stored as NULL where
///|   that is true, so a round-trip check must expect one fewer value.
///| - `Dialect::boolean_text`: a mode whose boolean column is a numeric flag
///|   takes `1` and `0` as field text, and `pg` mode takes `t` and `f`.
pub struct CopyStream {
  client : Client
}

pub fn Client::copy_in(self : Client, sql : String) -> CopyStream raise {
  let w = @wire.new_writer(sql.length() + 8)
  w.cstring(sql)
  send_message(self, b'Q', w.payload(), "copy begin")
  // No data may be sent before CopyInResponse arrives.
  let m = read_message(self)
  if m.tag == b'E' {
    let e = server_error_from(m.body)
    // The server still owes a ReadyForQuery. Read to it, or the next statement
    // on this connection would be answered with the tail of this refusal.
    drain_to_ready(self)
    fail(e.describe())
  }
  if m.tag != b'G' {
    fail("expected CopyInResponse, got '\\{m.tag.to_char()}'")
  }
  { client: self }
}

///| Sends one CopyData message. The 5-byte header and the payload are two
///| separate writes, so multi-megabyte batches are never copied just to prefix
///|
/// them with a header.
pub fn CopyStream::send_data(self : CopyStream, payload : Bytes) -> Unit raise {
  let n = payload.length()
  if n == 0 {
    return
  }
  send_raw(self.client, @wire.header(b'd', n), "copy header")
  send_raw(self.client, payload, "copy data")
}

///|
/// Ends the stream and returns the command tag, e.g. "COPY 10000000".
pub fn CopyStream::finish(self : CopyStream) -> String raise {
  let empty = Bytes::make(0, b'\x00')
  send_message(self.client, b'c', empty, "copy done")
  let mut command = ""
  while true {
    let m = read_message(self.client)
    if m.tag == b'C' {
      command = text_at(m.body, 0)
    } else if m.tag == b'E' {
      let e = server_error_from(m.body)
      drain_to_ready(self.client)
      fail(e.describe())
    } else if m.tag == b'Z' {
      self.client.transaction_status = m.body[0]
      return command
    }
  } nobreak {
    fail("unreachable")
  }
}

///|
/// Escapes one text-COPY field.
pub fn escape_copy_field(buf : @buffer.Buffer, value : String) -> Unit {
  let raw = @encoding/utf8.encode(value)
  let n = raw.length()
  let mut i = 0
  while i < n {
    let c = raw[i]
    if c == b'\\' {
      buf.write_byte(b'\\')
      buf.write_byte(b'\\')
    } else if c == b'\t' {
      buf.write_byte(b'\\')
      buf.write_byte(b't')
    } else if c == b'\n' {
      buf.write_byte(b'\\')
      buf.write_byte(b'n')
    } else if c == b'\r' {
      buf.write_byte(b'\\')
      buf.write_byte(b'r')
    } else {
      buf.write_byte(c)
    }
    i = i + 1
  }
}

///|
/// The NULL marker used by text COPY.
pub fn write_copy_null(buf : @buffer.Buffer) -> Unit {
  buf.write_byte(b'\\')
  buf.write_byte(b'N')
}

///| One row of a text COPY batch.
///|
/// The row writes into a buffer the caller owns and reuses, so a loader builds no
/// `String` per field. Each `write_*` method adds the field separator itself, so
/// a caller cannot leave a row with the wrong field count.
pub struct CopyRow {
  buf : @buffer.Buffer
  mut fields : Int
}

///|
/// A row that writes into `buf`.
pub fn new_copy_row(buf : @buffer.Buffer) -> CopyRow {
  { buf, fields: 0 }
}

///|
/// Starts one field and hands over the buffer.
///|
/// Use this for a value that is cheaper to write as bytes than to build as a
/// `String`, e.g. a timestamp written digit by digit. At 10M rows the encoder,
/// not the server, is the limit, so no row may cost an allocation per field.
pub fn CopyRow::start_field(self : CopyRow) -> @buffer.Buffer {
  self.begin_field()
  self.buf
}

fn CopyRow::begin_field(self : CopyRow) -> Unit {
  if self.fields > 0 {
    // The text COPY separator is a tab.
    self.buf.write_byte(b'\t')
  }
  self.fields = self.fields + 1
}

///|
/// Writes a decimal count with no fraction digits.
pub fn CopyRow::write_int(self : CopyRow, v : Int) -> Unit {
  self.begin_field()
  @wire.write_uint_decimal(self.buf, v)
}

///|
/// Writes a signed 64-bit count.
pub fn CopyRow::write_int64(self : CopyRow, v : Int64) -> Unit {
  self.begin_field()
  @wire.write_int64_decimal(self.buf, v)
}

///|
/// Writes `v / 10^scale` with exactly `scale` fraction digits.
pub fn CopyRow::write_decimal(self : CopyRow, v : Int64, scale : Int) -> Unit {
  self.begin_field()
  @wire.write_scaled_decimal(self.buf, v, scale)
}

///|
/// Writes a text field with the text-COPY escapes applied.
pub fn CopyRow::write_text(self : CopyRow, value : String) -> Unit {
  self.begin_field()
  escape_copy_field(self.buf, value)
}

///|
/// Writes the NULL marker.
pub fn CopyRow::write_null(self : CopyRow) -> Unit {
  self.begin_field()
  write_copy_null(self.buf)
}

///|
/// Writes a text field, or NULL when there is no value.
pub fn CopyRow::write_opt_text(self : CopyRow, value : String?) -> Unit {
  match value {
    None => self.write_null()
    Some(v) => self.write_text(v)
  }
}

///|
/// Writes a boolean as the text this mode expects.
pub fn CopyRow::write_bool(self : CopyRow, d : Dialect, value : Bool) -> Unit {
  self.begin_field()
  self.buf.write_string_utf8(d.boolean_text(value))
}

///|
/// Ends the row. A newline is what separates rows in text COPY.
pub fn CopyRow::end_row(self : CopyRow) -> Unit {
  self.buf.write_byte(b'\n')
  self.fields = 0
}

///|
/// Bytes written so far, which is how a loader decides that a batch is full.
pub fn CopyRow::len(self : CopyRow) -> Int {
  self.buf.length()
}

///|
/// The batch as one owned `Bytes`, and an empty row ready for the next batch.
///|
/// The buffer keeps its capacity, so a loader that sends batch after batch
/// allocates once, and the payload still goes out as two writes: the 5-byte
/// header and these bytes.
pub fn CopyRow::take(self : CopyRow) -> Bytes {
  let b = self.buf.to_bytes()
  self.buf.reset()
  self.fields = 0
  b
}

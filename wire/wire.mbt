///| PostgreSQL/KingbaseES message framing helpers: big-endian writers and the
///| 5-byte message header used when a payload is sent separately.
///|
///| Small messages (startup, auth, queries) are built as one contiguous buffer.
///| Bulk COPY payloads are far too large to copy, so their header is written as
///|
/// a separate 5-byte send next to the payload; `header` builds those bytes.
pub struct Writer {
  buf : @buffer.Buffer
}

pub fn new_writer(size_hint : Int) -> Writer {
  { buf: @buffer.new(size_hint~) }
}

pub fn Writer::byte(self : Writer, v : Byte) -> Unit {
  self.buf.write_byte(v)
}

pub fn Writer::int16(self : Writer, v : Int) -> Unit {
  self.buf.write_int16_be(Int16::from_int(v))
}

pub fn Writer::int32(self : Writer, v : Int) -> Unit {
  self.buf.write_int_be(v)
}

pub fn Writer::int64(self : Writer, v : Int64) -> Unit {
  self.buf.write_int64_be(v)
}

pub fn Writer::bytes(self : Writer, b : Bytes) -> Unit {
  self.buf.write_bytes(b)
}

///|
/// Writes text without a terminator.
pub fn Writer::text(self : Writer, s : String) -> Unit {
  self.buf.write_string_utf8(s)
}

///| Writes text followed by a NUL, which is how the protocol encodes names and
///|
/// query strings.
pub fn Writer::cstring(self : Writer, s : String) -> Unit {
  self.buf.write_string_utf8(s)
  self.buf.write_byte(b'\x00')
}

pub fn Writer::len(self : Writer) -> Int {
  self.buf.length()
}

///|
/// The accumulated payload, as an owned `Bytes`.
pub fn Writer::payload(self : Writer) -> Bytes {
  self.buf.to_bytes()
}

///| Payload prefixed with `tag` and a big-endian length that counts itself,
///|
/// i.e. a complete protocol message ready for a single write.
pub fn Writer::framed(self : Writer, tag : Byte) -> Bytes {
  let body = self.buf.to_bytes()
  let out = @buffer.new(size_hint=body.length() + 5)
  out.write_byte(tag)
  out.write_int_be(body.length() + 4)
  out.write_bytes(body)
  out.to_bytes()
}

///|
/// Builds only the 5-byte header for a payload that is written separately.
pub fn header(tag : Byte, body_len : Int) -> Bytes {
  let out = @buffer.new(size_hint=5)
  out.write_byte(tag)
  out.write_int_be(body_len + 4)
  out.to_bytes()
}

///|
/// Writes a non-negative Int as decimal text without allocating a String.
pub fn write_uint_decimal(buf : @buffer.Buffer, v : Int) -> Unit {
  if v == 0 {
    buf.write_byte(b'0')
    return
  }
  let mut div = 1
  let mut x = v
  while x >= 10 {
    div = div * 10
    x = x / 10
  }
  let mut rest = v
  while div > 0 {
    buf.write_byte((48 + rest / div).to_byte())
    rest = rest % div
    div = div / 10
  }
}

///|
/// Writes an Int64 as decimal text, with an optional leading minus sign.
pub fn write_int64_decimal(buf : @buffer.Buffer, v : Int64) -> Unit {
  if v == 0L {
    buf.write_byte(b'0')
    return
  }
  let mut x = v
  if x < 0L {
    buf.write_byte(b'-')
    x = 0L - x
  }
  let mut div = 1L
  let mut t = x
  while t >= 10L {
    div = div * 10L
    t = t / 10L
  }
  let mut rest = x
  while div > 0L {
    buf.write_byte((48 + (rest / div).to_int()).to_byte())
    rest = rest % div
    div = div / 10L
  }
}

///| Writes `v / 10^decimals` with exactly `decimals` fraction digits, e.g.
///|
/// 1234567 with decimals=4 becomes "123.4567". Used for numeric(18,4) amounts.
pub fn write_scaled_decimal(
  buf : @buffer.Buffer,
  v : Int64,
  decimals : Int,
) -> Unit {
  let mut div = 1L
  let mut i = 0
  while i < decimals {
    div = div * 10L
    i = i + 1
  }
  let mut neg = false
  let mut x = v
  if x < 0L {
    neg = true
    x = 0L - x
  }
  let whole = x / div
  let mut frac = x - whole * div
  if neg {
    buf.write_byte(b'-')
  }
  write_int64_decimal(buf, whole)
  if decimals > 0 {
    buf.write_byte(b'.')
    let mut scale = div / 10L
    while scale > 0L {
      let d = frac / scale
      frac = frac - d * scale
      buf.write_byte((48 + d.to_int()).to_byte())
      scale = scale / 10L
    }
  }
}

///| Operating-system shims: blocking Winsock2 sockets, monotonic clock, entropy.
///| All FFI pointer parameters are `#borrow`, so MoonBit keeps ownership of the
///|
/// buffers and a `Bytes` can be re-sent or inspected after the call returns.
extern "C" fn net_init() -> Int = "kb_net_init"

///|
#borrow(host)
extern "C" fn raw_connect(host : Bytes, port : Int) -> Int64 = "kb_connect"

extern "C" fn raw_close(sock : Int64) -> Unit = "kb_close"

///|
#borrow(data)
extern "C" fn raw_send(sock : Int64, data : Bytes, len : Int) -> Int = "kb_send_all"

///|
#borrow(data)
extern "C" fn raw_send_slice(
  sock : Int64,
  data : Bytes,
  offset : Int,
  len : Int,
) -> Int = "kb_send_slice"

extern "C" fn raw_set_nodelay(sock : Int64, on : Int) -> Int = "kb_set_tcp_nodelay"

extern "C" fn raw_set_send_buffer(sock : Int64, bytes : Int) -> Int = "kb_set_send_buffer"

extern "C" fn raw_read(sock : Int64, n : Int) -> Bytes? = "kb_read_bytes"

extern "C" fn raw_random(n : Int) -> Bytes = "kb_random_bytes"

extern "C" fn raw_now_us() -> Int64 = "kb_now_us"

extern "C" fn raw_sleep(ms : Int) -> Unit = "kb_sleep_ms"

pub struct Socket(Int64) derive(Debug, Eq, Compare)

pub struct IOError(String) derive(Debug, Eq, Compare, Show)

///|
/// NUL-terminated C string as `Bytes`, since `String` has no stable C ABI.
pub fn cstr(s : String) -> Bytes {
  let buf = @buffer.new()
  buf.write_string_utf8(s)
  buf.write_byte(b'\x00')
  buf.to_bytes()
}

pub fn connect(host : String, port : Int) -> Result[Socket, IOError] {
  let _ = net_init()
  let h = raw_connect(cstr(host), port)
  if h < 0 {
    Err(IOError("connect \{host}:\{port} failed, winsock code \{h}"))
  } else {
    let _ = raw_set_nodelay(h, 1)
    Ok(Socket(h))
  }
}

pub fn Socket::set_nodelay(self : Socket, on : Bool) -> Unit {
  let _ = raw_set_nodelay(self.0, if on { 1 } else { 0 })
}

pub fn Socket::set_send_buffer(self : Socket, bytes : Int) -> Unit {
  let _ = raw_set_send_buffer(self.0, bytes)
}

fn check_sent(sock : Int64, n : Int) -> Result[Unit, IOError] {
  if n < 0 {
    Err(IOError("send on socket \{sock} failed, winsock code \{n}"))
  } else {
    Ok(())
  }
}

pub fn Socket::write(self : Socket, data : Bytes) -> Result[Unit, IOError] {
  check_sent(self.0, raw_send(self.0, data, data.length()))
}

///| Writes `len` bytes of `data` starting at `offset`, without copying.
///|
/// Lets a 5-byte message header and a large payload go out as two writes.
pub fn Socket::write_slice(
  self : Socket,
  data : Bytes,
  offset : Int,
  len : Int,
) -> Result[Unit, IOError] {
  check_sent(self.0, raw_send_slice(self.0, data, offset, len))
}

///|
/// Reads exactly `n` bytes into a fresh buffer.
pub fn Socket::read_exact(self : Socket, n : Int) -> Result[Bytes, IOError] {
  if n == 0 {
    return Ok(Bytes::make(0, b'\x00'))
  }
  match raw_read(self.0, n) {
    Some(b) => Ok(b)
    None => Err(IOError("connection closed while reading \{n} bytes"))
  }
}

pub fn Socket::read_byte(self : Socket) -> Result[Byte, IOError] {
  match self.read_exact(1) {
    Ok(b) => Ok(b[0])
    Err(e) => Err(e)
  }
}

pub fn Socket::read_int32_be(self : Socket) -> Result[Int, IOError] {
  match self.read_exact(4) {
    Ok(b) => Ok(be32(b, 0))
    Err(e) => Err(e)
  }
}

///| Reads one protocol message: tag byte, big-endian Int32 length (counting
///|
/// itself), then `length - 4` bytes of payload.
pub fn Socket::read_message(self : Socket) -> Result[Message, IOError] {
  let tag = match self.read_byte() {
    Ok(b) => b
    Err(e) => return Err(e)
  }
  let len = match self.read_int32_be() {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if len < 4 {
    return Err(IOError("bad message length \{len}"))
  }
  let body = match self.read_exact(len - 4) {
    Ok(b) => b
    Err(e) => return Err(e)
  }
  Ok({ tag, body })
}

pub fn Socket::close(self : Socket) -> Unit {
  raw_close(self.0)
}

///|
/// A protocol message: tag plus payload.
pub struct Message {
  tag : Byte
  body : Bytes
} derive(Debug)

pub fn Message::len(self : Message) -> Int {
  self.body.length()
}

///|
/// UTF-8-decodes payload bytes from `offset` up to the next NUL byte.
pub fn Message::text_from(self : Message, offset : Int) -> String {
  text_at(self.body, offset)
}

///| UTF-8-decodes `length` bytes of `b` starting at `offset`.
///|
///| `Bytes::to_unchecked_string` must not be used here: on the native target it
///| reinterprets the byte range as UTF-16 code units, so ASCII protocol text
///|
/// comes back as CJK mojibake.
pub fn text_slice(b : Bytes, offset : Int, length : Int) -> String {
  @encoding/utf8.decode_lossy(b[offset:offset + length])
}

///| UTF-8-decodes `b` from `offset` up to (but excluding) the next NUL byte,
///|
/// which is how the protocol terminates strings and startup parameters.
pub fn text_at(b : Bytes, offset : Int) -> String {
  let n = b.length()
  let mut i = offset
  while i < n && b[i] != b'\x00' {
    i = i + 1
  }
  text_slice(b, offset, i - offset)
}

///| Text of everything written into `buf` so far.
///|
///| `Buffer::to_string` reinterprets the bytes as code units on the native
///|
/// target, which garbles ASCII output, so decode explicitly.
pub fn buffer_text(buf : @buffer.Buffer) -> String {
  let b = buf.to_bytes()
  text_slice(b, 0, b.length())
}

pub fn be16(b : Bytes, off : Int) -> Int {
  (b[off].to_int() << 8) | b[off + 1].to_int()
}

pub fn be32(b : Bytes, off : Int) -> Int {
  let x = b[off].to_int()
  let y = b[off + 1].to_int()
  let z = b[off + 2].to_int()
  let w = b[off + 3].to_int()
  (x << 24) | (y << 16) | (z << 8) | w
}

pub fn be64(b : Bytes, off : Int) -> Int64 {
  let mut acc = 0L
  let mut i = 0
  while i < 8 {
    acc = (acc << 8) + b[off + i].to_int64()
    i = i + 1
  }
  acc
}

pub fn random_bytes(n : Int) -> Bytes {
  raw_random(n)
}

///|
/// Monotonic clock in microseconds; the only clock used for timings.
pub fn now_us() -> Int64 {
  raw_now_us()
}

pub fn sleep_ms(ms : Int) -> Unit {
  raw_sleep(ms)
}

///|
test "bytes and buffer text decode as UTF-8" {
  // Guards the quirk that made the first working handshake garbled: on the
  // native target `Bytes::to_unchecked_string` and `Buffer::to_string` treat the
  // bytes as code units, so protocol and report text must go through UTF-8.
  let b = Buffer()
  b.write_string_utf8("SCRAM-SHA-256")
  let bytes = b.to_bytes()
  inspect(@sys.text_slice(bytes, 0, 13), content="SCRAM-SHA-256")
  inspect(@sys.text_at(bytes, 0), content="SCRAM-SHA-256")
  inspect(@sys.buffer_text(b), content="SCRAM-SHA-256")
}

///|
test "text_at stops at the first NUL" {
  let b = Buffer()
  b.write_string_utf8("COPY 100")
  b.write_byte(b'\x00')
  b.write_string_utf8("trailing")
  inspect(@sys.text_at(b.to_bytes(), 0), content="COPY 100")
}

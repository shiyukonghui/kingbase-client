///| SCRAM-SHA-256 client, specialised to what KingbaseES V9R1C010 accepts.
///|
///| KingbaseES follows RFC 5802 with two quirks verified against the live
///| server: the client-first-message keeps its `n,,` GS2 header and uses the
///| anonymous username `n=*` (the role itself comes from the startup packet),
///| and the AuthMessage is computed over the *bare* message, i.e. with the GS2
///|
/// header removed. `c=biws` is base64 of `n,,`, meaning "no channel binding".
priv struct ScramState {
  client_first : String
  client_nonce : String
}

///| SASLInitialResponse payload: mechanism name, NUL, the byte length of the
///|
/// client-first-message, then the message itself.
fn scram_initial_response(cf : String) -> Bytes {
  let w = @wire.new_writer(24 + cf.length())
  w.text("SCRAM-SHA-256")
  w.byte(b'\x00')
  w.int32(cf.length())
  w.text(cf)
  w.payload()
}

///|
/// Client-first-message plus the nonce it embeds.
fn scram_client_first(nonce_bytes : Int) -> ScramState {
  let cnonce = @crypto.base64_encode(@sys.random_bytes(nonce_bytes))
  let cf = "n,,n=*,r=\{cnonce}"
  { client_first: cf, client_nonce: cnonce }
}

///|
/// Value of a single-letter SCRAM attribute (`r=`, `s=`, `i=`).
fn scram_attr(server_msg : String, key : String) -> String {
  for part in server_msg.split(",") {
    if part.has_prefix(key) {
      return part[key.length():].to_string()
    }
  }
  ""
}

priv struct ScramReply {
  client_final : String
  server_signature : String
}

///|
/// Computes the client-final message and the signature the server must return.
fn scram_respond(
  state : ScramState,
  server_first : String,
  password : String,
) -> Result[ScramReply, String] {
  let server_nonce = scram_attr(server_first, "r=")
  let salt_b64 = scram_attr(server_first, "s=")
  let iters_str = scram_attr(server_first, "i=")
  if !server_nonce.has_prefix(state.client_nonce) {
    return Err("nonce mismatch")
  }
  let salt = match @crypto.base64_decode(salt_b64) {
    Ok(b) => b
    Err(e) => return Err("bad salt: \{e}")
  }
  let parsed : Result[Int, String] = Ok(@strconv.parse_int(iters_str)) catch {
    _ => Err("bad iteration count '\{iters_str}'")
  }
  let iters = match parsed {
    Ok(n) if n > 0 => n
    Ok(_) => return Err("iteration count must be positive")
    Err(msg) => return Err(msg)
  }
  let without_proof = "c=biws,r=\{server_nonce}"
  // RFC 5802: the AuthMessage uses the bare client-first-message, so the
  // 3-byte GS2 header is dropped here.
  let bare_first = state.client_first[3:]
  let auth_message = @encoding/utf8.encode(
    "\{bare_first},\{server_first},\{without_proof}",
  )
  let salted = @crypto.pbkdf2_hmac_sha256(
    @encoding/utf8.encode(password),
    salt,
    iters,
    32,
  )
  let client_key = @crypto.hmac_sha256(salted, b"Client Key")
  let stored_key = @crypto.sha256(client_key)
  let client_sig = @crypto.hmac_sha256(stored_key, auth_message)
  let proof_buf = @buffer.new()
  let mut i = 0
  while i < 32 {
    let x = (client_key[i].to_int() ^ client_sig[i].to_int()).to_byte()
    proof_buf.write_byte(x)
    i = i + 1
  }
  let proof = proof_buf.to_bytes()
  let server_key = @crypto.hmac_sha256(salted, b"Server Key")
  let server_sig = @crypto.hmac_sha256(server_key, auth_message)
  let final_msg = "\{without_proof},p=\{@crypto.base64_encode(proof)}"
  let sig_text = @crypto.base64_encode(server_sig)
  Ok({ client_final: final_msg, server_signature: sig_text })
}

///|
/// The SASLFinal payload the server must echo, proving the same password.
fn scram_expected_server_final(reply : ScramReply) -> String {
  "v=\{reply.server_signature}"
}

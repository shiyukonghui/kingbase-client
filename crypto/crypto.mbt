///| Pure-MoonBit crypto primitives for PostgreSQL / KingbaseES SCRAM-SHA-256
/// authentication: SHA-256, HMAC-SHA-256, PBKDF2-HMAC-SHA-256 and standard
/// base64. No FFI, no external dependencies.

// --- SHA-256 ---------------------------------------------------------------

///|
/// The 64 round constants of SHA-256 (high 32 bits of the fractional parts of
/// the cube roots of the first 64 primes).
let k : Array[UInt] = [
  0x428a2f98U, 0x71374491U, 0xb5c0fbcfU, 0xe9b5dba5U, 0x3956c25bU, 0x59f111f1U, 0x923f82a4U,
  0xab1c5ed5U, 0xd807aa98U, 0x12835b01U, 0x243185beU, 0x550c7dc3U, 0x72be5d74U, 0x80deb1feU,
  0x9bdc06a7U, 0xc19bf174U, 0xe49b69c1U, 0xefbe4786U, 0x0fc19dc6U, 0x240ca1ccU, 0x2de92c6fU,
  0x4a7484aaU, 0x5cb0a9dcU, 0x76f988daU, 0x983e5152U, 0xa831c66dU, 0xb00327c8U, 0xbf597fc7U,
  0xc6e00bf3U, 0xd5a79147U, 0x06ca6351U, 0x14292967U, 0x27b70a85U, 0x2e1b2138U, 0x4d2c6dfcU,
  0x53380d13U, 0x650a7354U, 0x766a0abbU, 0x81c2c92eU, 0x92722c85U, 0xa2bfe8a1U, 0xa81a664bU,
  0xc24b8b70U, 0xc76c51a3U, 0xd192e819U, 0xd6990624U, 0xf40e3585U, 0x106aa070U, 0x19a4c116U,
  0x1e376c08U, 0x2748774cU, 0x34b0bcb5U, 0x391c0cb3U, 0x4ed8aa4aU, 0x5b9cca4fU, 0x682e6ff3U,
  0x748f82eeU, 0x78a5636fU, 0x84c87814U, 0x8cc70208U, 0x90befffaU, 0xa4506cebU, 0xbef9a3f7U,
  0xc67178f2U,
]

///|
/// Right-rotation of a 32-bit word by a constant amount.
fn rotr(x : UInt, n : Int) -> UInt {
  (x >> n) | (x << (32 - n))
}

///|
/// One SHA-256 compression of the 512-bit block at `base` in `msg`, folding
/// the result into the running state `h`.
fn sha256_compress(msg : Bytes, base : Int, h : Array[UInt]) -> Unit {
  let w : Array[UInt] = Array::make(64, 0U)
  let mut t = 0
  while t < 16 {
    let o = base + t * 4
    w[t] = (msg[o].to_uint() << 24) |
      (msg[o + 1].to_uint() << 16) |
      (msg[o + 2].to_uint() << 8) |
      msg[o + 3].to_uint()
    t = t + 1
  }
  while t < 64 {
    let s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >> 3)
    let s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >> 10)
    w[t] = w[t - 16] + s0 + w[t - 7] + s1
    t = t + 1
  }
  let mut a = h[0]
  let mut b = h[1]
  let mut c = h[2]
  let mut d = h[3]
  let mut e = h[4]
  let mut f = h[5]
  let mut g = h[6]
  let mut hh = h[7]
  let mut i = 0
  while i < 64 {
    let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
    let ch = (e & f) ^ (e.lnot() & g)
    let temp1 = hh + s1 + ch + k[i] + w[i]
    let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
    let maj = (a & b) ^ (a & c) ^ (b & c)
    let temp2 = s0 + maj
    hh = g
    g = f
    f = e
    e = d + temp1
    d = c
    c = b
    b = a
    a = temp1 + temp2
    i = i + 1
  }
  h[0] = h[0] + a
  h[1] = h[1] + b
  h[2] = h[2] + c
  h[3] = h[3] + d
  h[4] = h[4] + e
  h[5] = h[5] + f
  h[6] = h[6] + g
  h[7] = h[7] + hh
}

///|
/// SHA-256 digest of `data`, returned as 32 big-endian bytes.
pub fn sha256(data : Bytes) -> Bytes {
  let padded = Buffer()
  padded.write_bytes(data)
  padded.write_byte(b'\x80')
  while padded.length() % 64 != 56 {
    padded.write_byte(b'\x00')
  }
  padded.write_uint64_be(data.length().to_uint64() * 8UL)
  let msg = padded.to_bytes()
  let h : Array[UInt] = [
    0x6a09e667U, 0xbb67ae85U, 0x3c6ef372U, 0xa54ff53aU, 0x510e527fU, 0x9b05688cU,
    0x1f83d9abU, 0x5be0cd19U,
  ]
  let mut base = 0
  while base < msg.length() {
    sha256_compress(msg, base, h)
    base = base + 64
  }
  let out = Buffer()
  let mut j = 0
  while j < 8 {
    out.write_byte((h[j] >> 24).to_byte())
    out.write_byte((h[j] >> 16).to_byte())
    out.write_byte((h[j] >> 8).to_byte())
    out.write_byte(h[j].to_byte())
    j = j + 1
  }
  out.to_bytes()
}

// --- HMAC-SHA-256 ----------------------------------------------------------

///|
/// RFC 2104 HMAC built on SHA-256 (block size 64 bytes, standard ipad/opad).
pub fn hmac_sha256(key : Bytes, msg : Bytes) -> Bytes {
  let k = if key.length() > 64 { sha256(key) } else { key }
  let klen = k.length()
  let inner = Buffer()
  let mut i = 0
  while i < 64 {
    let kb = if i < klen { k[i].to_int() } else { 0 }
    inner.write_byte((kb ^ 0x36).to_byte())
    i = i + 1
  }
  inner.write_bytes(msg)
  let inner_hash = sha256(inner.to_bytes())
  let outer = Buffer()
  i = 0
  while i < 64 {
    let kb = if i < klen { k[i].to_int() } else { 0 }
    outer.write_byte((kb ^ 0x5c).to_byte())
    i = i + 1
  }
  outer.write_bytes(inner_hash)
  sha256(outer.to_bytes())
}

// --- PBKDF2-HMAC-SHA-256 ---------------------------------------------------

///|
/// PBKDF2 (RFC 6070 / RFC 8018) using HMAC-SHA-256 as the PRF. The block
/// counter appended to the salt is a big-endian `UInt32` starting at 1, and
/// each round XORs `U_i = PRF(password, U_{i-1})` (with `U_1 = PRF(password,
/// salt || BE32(1))`).
pub fn pbkdf2_hmac_sha256(
  password : Bytes,
  salt : Bytes,
  iterations : Int,
  dk_len : Int,
) -> Bytes {
  let out = Buffer()
  let mut block_idx = 1
  while out.length() < dk_len {
    // U_1 = PRF(password, salt || BE32(block_idx))
    let pre = Buffer()
    pre.write_bytes(salt)
    pre.write_byte((block_idx >> 24).to_byte())
    pre.write_byte((block_idx >> 16).to_byte())
    pre.write_byte((block_idx >> 8).to_byte())
    pre.write_byte(block_idx.to_byte())
    let mut u = hmac_sha256(password, pre.to_bytes())
    // T = U_1, then XOR the remaining U_i in.
    let t : Array[Int] = Array::make(32, 0)
    let mut j = 0
    while j < 32 {
      t[j] = u[j].to_int()
      j = j + 1
    }
    let mut iter = 1
    while iter < iterations {
      u = hmac_sha256(password, u)
      j = 0
      while j < 32 {
        t[j] = t[j] ^ u[j].to_int()
        j = j + 1
      }
      iter = iter + 1
    }
    j = 0
    while j < 32 && out.length() < dk_len {
      out.write_byte(t[j].to_byte())
      j = j + 1
    }
    block_idx = block_idx + 1
  }
  out.to_bytes()
}

// --- Base64 ----------------------------------------------------------------

///|
/// The standard base64 alphabet, indexed by sextet value.
let b64_alphabet : Bytes = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

///|
/// Maps an ASCII byte to its base64 sextet value, or `-1` when it is not a
/// member of the standard alphabet.
fn b64_val(ch : Int) -> Int {
  if ch >= 65 && ch <= 90 {
    ch - 65
  } else if ch >= 97 && ch <= 122 {
    ch - 71
  } else if ch >= 48 && ch <= 57 {
    ch + 4
  } else if ch == 43 {
    62
  } else if ch == 47 {
    63
  } else {
    -1
  }
}

///|
/// Standard base64 encoding with `=` padding.
pub fn base64_encode(data : Bytes) -> String {
  let n = data.length()
  let sb = StringBuilder()
  let mut i = 0
  while i + 3 <= n {
    let v = (data[i].to_int() << 16) |
      (data[i + 1].to_int() << 8) |
      data[i + 2].to_int()
    sb.write_char(b64_alphabet[(v >> 18) & 63].to_char())
    sb.write_char(b64_alphabet[(v >> 12) & 63].to_char())
    sb.write_char(b64_alphabet[(v >> 6) & 63].to_char())
    sb.write_char(b64_alphabet[v & 63].to_char())
    i = i + 3
  }
  let rem = n - i
  if rem == 1 {
    let v = data[i].to_int() << 16
    sb.write_char(b64_alphabet[(v >> 18) & 63].to_char())
    sb.write_char(b64_alphabet[(v >> 12) & 63].to_char())
    sb.write_string("==")
  } else if rem == 2 {
    let v = (data[i].to_int() << 16) | (data[i + 1].to_int() << 8)
    sb.write_char(b64_alphabet[(v >> 18) & 63].to_char())
    sb.write_char(b64_alphabet[(v >> 12) & 63].to_char())
    sb.write_char(b64_alphabet[(v >> 6) & 63].to_char())
    sb.write_char('=')
  }
  sb.to_string()
}

///|
/// Decodes a standard, padded base64 string. Rejects any length that is not a
/// multiple of 4, non-alphabet characters, data after padding, and
/// non-canonical trailing bits. Round-trips with `base64_encode`.
pub fn base64_decode(s : String) -> Result[Bytes, String] {
  let n = s.length()
  if n == 0 {
    return Ok(Buffer().to_bytes())
  }
  if n % 4 != 0 {
    return Err("base64: input length must be a multiple of 4")
  }
  let buf = Buffer()
  let mut acc = 0
  let mut nbits = 0
  let mut seen_pad = false
  let mut i = 0
  for idx, c in s {
    ignore(idx)
    let ch = c.to_int()
    let pos = i % 4
    if ch == 0x3d {
      // '=' padding: only valid as the 3rd or 4th char of a group.
      if pos < 2 {
        return Err("base64: padding in an invalid position")
      }
      seen_pad = true
    } else if seen_pad {
      return Err("base64: data after padding")
    } else {
      let v = b64_val(ch)
      if v < 0 {
        return Err("base64: invalid character")
      }
      acc = (acc << 6) | v
      nbits = nbits + 6
      if nbits >= 8 {
        nbits = nbits - 8
        buf.write_byte(((acc >> nbits) & 0xff).to_byte())
        acc = acc & ((1 << nbits) - 1)
      }
    }
    i = i + 1
  }
  if acc != 0 {
    Err("base64: non-canonical trailing bits")
  } else {
    Ok(buf.to_bytes())
  }
}

/// M-02: what leaves the app as a log (copy, export, share) has no secrets and no server addresses.
///
/// Masks: proxy and profile links (vless://, ss://, vpn:// ...) whole; the path, query and user of
/// http(s) URLs (subscription tokens); UUIDs; base64 keys of 32 bytes (WireGuard/AmneziaWG/Reality);
/// key=value secrets (password, private_key, pbk, sid, token ...); IPv4 and IPv6 addresses.
/// Host names other than in links stay: without them a log tells nothing.
String scrubSecrets(String text) {
  var out = text;
  // links of proxies and profiles: their whole body is the secret
  out = out.replaceAllMapped(
    RegExp(
      r'\b(vless|vmess|trojan|ss|ssr|ssconf|hy2|hysteria2?|tuic|wg|wireguard|awg|vpn|ssh|anytls|shadowtls|mieru|naive\+https|naive\+quic|socks5?|warp|ovpn|sandpiper|hiddify)://\S+',
      caseSensitive: false,
    ),
    (m) => '${m[1]}://[redacted]',
  );
  // http(s) URLs: the host stays, the user, path and query (tokens) go
  out = out.replaceAllMapped(
    RegExp(r'\b(https?)://(?:[^\s/@]+@)?([^\s/?#:]+)(:\d+)?([/?#]\S*)?', caseSensitive: false),
    (m) => '${m[1]}://${m[2]}${m[3] ?? ''}${(m[4] ?? '').isEmpty ? '' : '/[redacted]'}',
  );
  // key=value and "key": "value" secrets
  out = out.replaceAllMapped(
    RegExp(
      r'''(\b(?:password|passwd|pass|psk|private_key|privatekey|preshared_key|presharedkey|public_key|publickey|pbk|sid|short_id|uuid|token|secret|auth|header_protection_key|license[_-]?key|alt-url|alt_url)\b"?\s*[:=]\s*"?)([^\s",;&]+)''',
      caseSensitive: false,
    ),
    (m) => '${m[1]}[redacted]',
  );
  // the other subscription of a profile's pair (the profile-exits header): its link in base64url, which
  // starts the same for any https link, whatever key it is under
  out = out.replaceAll(RegExp('(?<![A-Za-z0-9_+/-])aHR0cHM6Ly[A-Za-z0-9_+/-]*=*'), '[link]');
  // UUIDs
  out = out.replaceAll(
    RegExp(r'\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b', caseSensitive: false),
    '[uuid]',
  );
  // 32-byte keys in base64 (44 characters ending in "=")
  out = out.replaceAll(RegExp('(?<![A-Za-z0-9+/])[A-Za-z0-9+/]{43}='), '[key]');
  // IPv4
  out = out.replaceAll(RegExp(r'\b(?:25[0-5]|2[0-4]\d|1?\d?\d)(?:\.(?:25[0-5]|2[0-4]\d|1?\d?\d)){3}\b'), '[ip]');
  // IPv6: five groups or more, or with "::" and a group beside it (times like 12:30:45 stay)
  out = out.replaceAll(
    RegExp(r'(?<![\w:.])(?:[0-9a-f]{1,4}:){4,7}[0-9a-f]{1,4}(?![\w:])', caseSensitive: false),
    '[ip6]',
  );
  out = out.replaceAll(
    RegExp(
      r'(?<![\w:.])(?:(?:[0-9a-f]{1,4}:)+:(?:[0-9a-f]{1,4}(?::[0-9a-f]{1,4})*)?|::[0-9a-f]{1,4}(?::[0-9a-f]{1,4})*)(?![\w:])',
      caseSensitive: false,
    ),
    '[ip6]',
  );
  return out;
}

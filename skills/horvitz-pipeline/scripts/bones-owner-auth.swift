// bones-owner-auth.swift — Horvitz owner-auth helper (macOS).
//
// Built locally by `bones owner-setup` into ~/.bones-owner/bones-owner-auth. The signing key is a
// PERMANENT Secure-Enclave P-256 key whose access control requires biometry (Touch ID) for every
// signature, so a process running as the same user can ASK for a signature but cannot produce one
// without the owner's finger. bones.sh pins this binary's sha256 + cdhash next to the public key and
// refuses to invoke a helper that differs.
//
//   bones-owner-auth setup  --label <label> [--policy biometry|presence] [--reset]   -> {"pub_b64":…}
//   bones-owner-auth pubkey --label <label>                                           -> {"pub_b64":…}
//   bones-owner-auth sign   --label <label> --pipeline <name> --stage <n> --git-sha <sha>
//                           --quote-sha <sha256 of the owner quote> --nonce <hex> --ts <unix>
//                           [--quote <first 60 chars, shown in the prompt>]
//                           -> {"payload":"v1|name|stage|git-sha|quote-sha|nonce|ts","sig_b64":…,"pub_b64":…}
// pub_b64 is the X9.63 uncompressed point (65 bytes); bones.sh wraps it into SPKI PEM for openssl.
// Exit codes: 0 ok; 2 usage; 3 key error; 4 user cancelled / biometry failed; 5 signing failed.
import Foundation
import LocalAuthentication
import Security

func out(_ s: String) { print(s); fflush(stdout) }
func fail(_ code: Int32, _ msg: String) -> Never { FileHandle.standardError.write((msg + "\n").data(using: .utf8)!); exit(code) }
func arg(_ name: String) -> String? { let a = CommandLine.arguments; if let i = a.firstIndex(of: name), i + 1 < a.count { return a[i + 1] }; return nil }
func has(_ name: String) -> Bool { CommandLine.arguments.contains(name) }
func b64(_ d: Data) -> String { d.base64EncodedString() }

let args = CommandLine.arguments
guard args.count >= 2 else { fail(2, "usage: bones-owner-auth setup|pubkey|sign --label <label> …") }
let cmd = args[1]
let label = arg("--label") ?? "bones-owner-\(Host.current().localizedName ?? "mac")"
let tag = label.data(using: .utf8)!

func findKey(_ ctx: LAContext? = nil) -> SecKey? {
  var q: [String: Any] = [
    kSecClass as String: kSecClassKey,
    kSecAttrApplicationTag as String: tag,
    kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
    kSecReturnRef as String: true,
  ]
  if let c = ctx { q[kSecUseAuthenticationContext as String] = c }
  var item: CFTypeRef?
  let st = SecItemCopyMatching(q as CFDictionary, &item)
  if st != errSecSuccess { return nil }
  return (item as! SecKey)
}
func pubB64(_ key: SecKey) -> String {
  guard let pub = SecKeyCopyPublicKey(key), let d = SecKeyCopyExternalRepresentation(pub, nil) as Data? else { fail(3, "cannot export public key") }
  return b64(d)
}

switch cmd {
case "setup":
  let policy = arg("--policy") ?? "biometry"
  if has("--reset"), let _ = findKey() {
    let dq: [String: Any] = [kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag]
    SecItemDelete(dq as CFDictionary)
  }
  if let k = findKey() { out("{\"pub_b64\":\"\(pubB64(k))\",\"existing\":true}"); exit(0) }
  var flags: SecAccessControlCreateFlags = [.privateKeyUsage]
  switch policy {
  case "biometry": flags.insert(.biometryCurrentSet)
  case "presence": flags.insert(.userPresence)
  default: fail(2, "--policy must be biometry|presence")
  }
  var cfErr: Unmanaged<CFError>?
  guard let acl = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, &cfErr) else { fail(3, "access control: \(cfErr!.takeRetainedValue())") }
  let attrs: [String: Any] = [
    kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
    kSecAttrKeySizeInBits as String: 256,
    kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
    kSecAttrLabel as String: label,
    kSecPrivateKeyAttrs as String: [
      kSecAttrIsPermanent as String: true,
      kSecAttrApplicationTag as String: tag,
      kSecAttrAccessControl as String: acl,
    ],
  ]
  guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, &cfErr) else { fail(3, "Secure Enclave key creation failed: \(cfErr!.takeRetainedValue())") }
  out("{\"pub_b64\":\"\(pubB64(key))\",\"existing\":false,\"policy\":\"\(policy)\"}")
case "pubkey":
  guard let k = findKey() else { fail(3, "no owner key with label \(label) — run setup") }
  out("{\"pub_b64\":\"\(pubB64(k))\"}")
case "sign":
  guard let pipeline = arg("--pipeline"), let stage = arg("--stage"), let gitSha = arg("--git-sha"),
        let quoteSha = arg("--quote-sha"), let nonce = arg("--nonce"), let ts = arg("--ts") else {
    fail(2, "sign needs --pipeline --stage --git-sha --quote-sha --nonce --ts")
  }
  for (n, v) in [("pipeline", pipeline), ("stage", stage), ("git-sha", gitSha), ("quote-sha", quoteSha), ("nonce", nonce), ("ts", ts)] {
    if v.contains("|") || v.contains("\n") { fail(2, "\(n) must not contain | or newline") }
  }
  let payload = "v1|\(pipeline)|\(stage)|\(gitSha)|\(quoteSha)|\(nonce)|\(ts)"
  let quote = arg("--quote") ?? ""
  let short = String(gitSha.prefix(12))
  let ctx = LAContext()
  ctx.localizedReason = "Horvitz: authorize promote of \(pipeline) @ \(short) (stage \(stage))" + (quote.isEmpty ? "" : " — \u{201C}\(quote)\u{201D}")
  ctx.localizedCancelTitle = "Refuse"
  var err: NSError?
  if !ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) { fail(4, "biometrics unavailable: \(err?.localizedDescription ?? "?")") }
  guard let key = findKey(ctx) else { fail(3, "no owner key with label \(label) — run setup") }
  var cfErr: Unmanaged<CFError>?
  guard let sig = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, payload.data(using: .utf8)! as CFData, &cfErr) else {
    let e = cfErr!.takeRetainedValue() as Error
    fail(4, "signature refused (Touch ID cancelled/failed): \(e.localizedDescription)")
  }
  out("{\"payload\":\"\(payload)\",\"sig_b64\":\"\(b64(sig as Data))\",\"pub_b64\":\"\(pubB64(key))\"}")
default:
  fail(2, "unknown command \(cmd) (setup|pubkey|sign)")
}

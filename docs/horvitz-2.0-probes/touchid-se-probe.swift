// Spec-time dependency probe for Horvitz 2.0 owner-auth (stage 8a).
// Proves, from an unsigned/ad-hoc CLI binary on THIS Mac, without prompting:
//  1. LocalAuthentication can evaluate biometrics (Touch ID present + enrolled)
//  2. A Secure Enclave P-256 key can be created and used to sign (ephemeral, no ACL)
//  3. A biometry-gated access control can be attached to an SE key at creation
// It deliberately does NOT sign with the ACL key (that would prompt Touch ID).
import Foundation
import LocalAuthentication
import Security

func line(_ s: String) { print(s); fflush(stdout) }
let ctx = LAContext()
var err: NSError?
let canBio = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
line("1a canEvaluate(biometrics): \(canBio) \(err.map { "err=\($0.code) \($0.localizedDescription)" } ?? "")")
err = nil
let canAny = ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err)
line("1b canEvaluate(deviceOwnerAuthentication): \(canAny) \(err.map { "err=\($0.code)" } ?? "")")
line("1c biometryType raw: \(ctx.biometryType.rawValue) (1=touchID 2=faceID 0=none)")

var cfErr: Unmanaged<CFError>?
let attrs: [String: Any] = [
  kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
  kSecAttrKeySizeInBits as String: 256,
  kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
  kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: false],
]
if let key = SecKeyCreateRandomKey(attrs as CFDictionary, &cfErr) {
  line("2a SE ephemeral key create: OK")
  if let pub = SecKeyCopyPublicKey(key) {
    let msg = "horvitz-2.0 probe".data(using: .utf8)! as CFData
    if let sig = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, msg, &cfErr) {
      line("2b SE sign (no ACL, no prompt): OK, \(CFDataGetLength(sig)) bytes DER")
      let ok = SecKeyVerifySignature(pub, .ecdsaSignatureMessageX962SHA256, msg, sig, &cfErr)
      line("2c verify with SE public key: \(ok)")
      if let pubData = SecKeyCopyExternalRepresentation(pub, &cfErr) {
        line("2d public key export (X9.63): \(CFDataGetLength(pubData)) bytes -> openssl-verifiable")
      }
    } else { line("2b SE sign FAILED: \(cfErr!.takeRetainedValue())") }
  }
} else {
  line("2a SE ephemeral key create FAILED: \(cfErr!.takeRetainedValue())")
}

cfErr = nil
if let acl = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .biometryCurrentSet], &cfErr) {
  line("3a ACL(privateKeyUsage+biometryCurrentSet): OK")
  let attrs2: [String: Any] = [
    kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
    kSecAttrKeySizeInBits as String: 256,
    kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
    kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: false, kSecAttrAccessControl as String: acl],
  ]
  if SecKeyCreateRandomKey(attrs2 as CFDictionary, &cfErr) != nil {
    line("3b SE key WITH biometry ACL create (ephemeral, no prompt at creation): OK  [signing with it would prompt Touch ID — not done here]")
  } else { line("3b SE key with ACL create FAILED: \(cfErr!.takeRetainedValue())") }
} else { line("3a ACL create FAILED: \(cfErr!.takeRetainedValue())") }
line("probe done")

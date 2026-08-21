// Probe 2: dump an SE-signed payload so the bash/openssl verification path bones.sh will use is proven at spec time.
import Foundation
import Security
var cfErr: Unmanaged<CFError>?
let attrs: [String: Any] = [
  kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
  kSecAttrKeySizeInBits as String: 256,
  kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
  kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: false],
]
guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, &cfErr), let pub = SecKeyCopyPublicKey(key) else { print("key fail"); exit(1) }
let payload = "v1|horvitz-2.0|8|deadbeefcafe|quotehash|nonce123|1755808500"
let msg = payload.data(using: .utf8)!
guard let sig = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, msg as CFData, &cfErr) else { print("sign fail"); exit(1) }
guard let pubData = SecKeyCopyExternalRepresentation(pub, &cfErr) else { print("export fail"); exit(1) }
let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
try! msg.write(to: URL(fileURLWithPath: "\(dir)/msg.txt"))
try! (sig as Data).write(to: URL(fileURLWithPath: "\(dir)/sig.der"))
try! (pubData as Data).write(to: URL(fileURLWithPath: "\(dir)/pub.x963"))
print("dumped msg.txt (\(msg.count)B) sig.der (\((sig as Data).count)B) pub.x963 (\((pubData as Data).count)B)")

// 用 zip 里 App 自己内置的公钥(Info.plist 的 SUPublicEDKey)验 appcast 要用的 EdDSA 签名。
//
// 用法: swift .github/scripts/verify_sparkle_signature.swift <zip> <签名(base64)> [<zip> <签名> ...]
//
// release.yml 在写 appcast 之前、发布之前跑它。签名是 CI 密钥 SPARKLE_PRIVATE_KEY 算的,公钥写死在
// build.sh 里,两者配不上时 appcast 照样生成、形状校验照样通过,用户那边 Sparkle 验签失败、更新下载不下来,
// 没有任何报错指向这里。Sparkle 的签名是对整个 zip 字节做的标准 Ed25519,CryptoKit 能直接验。
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("verify_sparkle_signature: \(message)\n".utf8))
    exit(1)
}

func embeddedPublicKey(of zip: String) -> String {
    let unzip = Process()
    unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    unzip.arguments = ["-p", zip, "Lyrimuse.app/Contents/Info.plist"]
    let pipe = Pipe()
    unzip.standardOutput = pipe
    do { try unzip.run() } catch { fail("cannot run unzip on \(zip): \(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    unzip.waitUntilExit()
    guard unzip.terminationStatus == 0,
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let key = plist["SUPublicEDKey"] as? String, !key.isEmpty
    else { fail("\(zip) has no Lyrimuse.app/Contents/Info.plist with SUPublicEDKey") }
    return key
}

let args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty, args.count % 2 == 0 else {
    fail("usage: verify_sparkle_signature.swift <zip> <base64-signature> [<zip> <base64-signature> ...]")
}
var keys: Set<String> = []
for i in stride(from: 0, to: args.count, by: 2) {
    let zip = args[i]
    let keyText = embeddedPublicKey(of: zip)
    keys.insert(keyText)
    guard let keyData = Data(base64Encoded: keyText),
          let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    else { fail("\(zip): SUPublicEDKey is not a base64 Ed25519 public key") }
    guard let signature = Data(base64Encoded: args[i + 1]) else { fail("\(zip): signature is not base64") }
    guard let archive = FileManager.default.contents(atPath: zip) else { fail("cannot read \(zip)") }
    guard publicKey.isValidSignature(signature, for: archive) else {
        fail("\(zip): signature does not verify against the app's own SUPublicEDKey -- SPARKLE_PRIVATE_KEY and the key in build.sh are not a pair; every user's update would fail signature check")
    }
    print("ok  \(zip)")
}
if keys.count != 1 { fail("the zips embed different SUPublicEDKey values: \(keys.sorted())") }

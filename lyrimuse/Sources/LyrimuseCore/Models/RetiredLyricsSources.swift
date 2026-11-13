import Foundation

/// 已经下线的歌词源名。老版本写的设置文件(`lyrics_sources` / `lyrics_source_order`)里还带着它们,读的时候先剔掉:
/// 设置读取对不认识的源名是原样保留、写回时带上的(留给更新的版本加的源),下线的源不剔掉就会一直留在文件里。
/// 剔掉之后其余源名和顺序不动,写回时自然不再有它们。
public enum RetiredLyricsSources {
    public static let names: Set<String> = ["musixmatch"]

    /// 去掉下线的源名,其余按原顺序返回;nil(文件里没写这个键)原样返回 nil。
    public static func dropping(_ stored: [String]?) -> [String]? {
        stored?.filter { !names.contains($0) }
    }
}

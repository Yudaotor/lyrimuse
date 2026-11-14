import Foundation

/// 只活在内存里的 `UserDefaults`:读写都落在本对象的字典里,不连 cfprefsd、不建偏好文件。
///
/// 给「按全默认值造一份设置对象」这类一次性用途:真的 `UserDefaults(suiteName:)` 每次读写都要跟 cfprefsd 同步往返,
/// cfprefsd 忙的时候(登录后各个 App 一起起来)在主线程上一卡就是几十秒(14 章决策 194)。
///
/// 存取方法(`object` / `set` 各重载 / 按类型取值 / `removeObject` / `register` / `dictionaryRepresentation`)都在这里接住;
/// 父类按一个不会被写进去的临时域名初始化,没接住的方法才会落到那个空域上。按类型取值照 `UserDefaults` 的口径:
/// 数和字符串互相能转,取不到时返回 0 / false / nil。
public final class InMemoryUserDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    private var registered: [String: Any] = [:]

    /// 新建一份空的。别用无参的 `init()`:那是父类按标准域建的,没接住的方法会落到用户真实的偏好上。
    public static func make() -> InMemoryUserDefaults? {
        InMemoryUserDefaults(suiteName: LyrimuseIdentity.bundleIdentifier + ".in-memory-\(UUID().uuidString)")
    }

    override public init?(suiteName suitename: String?) {
        super.init(suiteName: suitename)
    }

    override public func object(forKey defaultName: String) -> Any? { values[defaultName] ?? registered[defaultName] }
    override public func value(forKey key: String) -> Any? { object(forKey: key) }

    /// 存成桥接后的对象(`NSNumber` / `NSString` / `NSArray` …),跟真的偏好读回来一样:存的整数按 `as? Double` 也取得到。
    override public func set(_ value: Any?, forKey defaultName: String) {
        if let value { values[defaultName] = value as AnyObject } else { values[defaultName] = nil }
    }
    override public func set(_ value: Int, forKey defaultName: String) { values[defaultName] = NSNumber(value: value) }
    override public func set(_ value: Float, forKey defaultName: String) { values[defaultName] = NSNumber(value: value) }
    override public func set(_ value: Double, forKey defaultName: String) { values[defaultName] = NSNumber(value: value) }
    override public func set(_ value: Bool, forKey defaultName: String) { values[defaultName] = NSNumber(value: value) }
    override public func set(_ url: URL?, forKey defaultName: String) { values[defaultName] = url.map { $0.absoluteString as NSString } }
    override public func removeObject(forKey defaultName: String) { values[defaultName] = nil }

    override public func string(forKey defaultName: String) -> String? {
        switch object(forKey: defaultName) {
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    override public func array(forKey defaultName: String) -> [Any]? { object(forKey: defaultName) as? [Any] }
    override public func dictionary(forKey defaultName: String) -> [String: Any]? { object(forKey: defaultName) as? [String: Any] }
    override public func data(forKey defaultName: String) -> Data? { object(forKey: defaultName) as? Data }

    override public func stringArray(forKey defaultName: String) -> [String]? {
        guard let array = object(forKey: defaultName) as? [Any] else { return nil }
        let strings = array.compactMap { $0 as? String }
        return strings.count == array.count ? strings : nil
    }

    override public func integer(forKey defaultName: String) -> Int {
        switch object(forKey: defaultName) {
        case let number as NSNumber: return number.intValue
        case let string as String: return Int(string) ?? Int(Double(string) ?? 0)
        default: return 0
        }
    }

    override public func float(forKey defaultName: String) -> Float { Float(double(forKey: defaultName)) }

    override public func double(forKey defaultName: String) -> Double {
        switch object(forKey: defaultName) {
        case let number as NSNumber: return number.doubleValue
        case let string as String: return Double(string) ?? 0
        default: return 0
        }
    }

    override public func bool(forKey defaultName: String) -> Bool {
        switch object(forKey: defaultName) {
        case let number as NSNumber: return number.boolValue
        case let string as String: return ["yes", "true"].contains(string.lowercased()) || (Int(string) ?? 0) != 0
        default: return false
        }
    }

    override public func url(forKey defaultName: String) -> URL? {
        switch object(forKey: defaultName) {
        case let url as URL: return url
        case let string as String: return string.hasPrefix("/") ? URL(fileURLWithPath: string) : URL(string: string)
        default: return nil
        }
    }

    override public func register(defaults registrationDictionary: [String: Any]) {
        registered.merge(registrationDictionary.mapValues { $0 as AnyObject }) { _, new in new }
    }

    override public func dictionaryRepresentation() -> [String: Any] { registered.merging(values) { _, own in own } }
    override public func synchronize() -> Bool { true }
}

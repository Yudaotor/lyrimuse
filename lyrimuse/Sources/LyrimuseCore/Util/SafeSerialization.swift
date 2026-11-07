import Foundation

/// JSON / 属性列表序列化前先查一遍对象合不合法。`JSONSerialization.data(withJSONObject:)` 遇到 Date、Data、NaN、非字符串键,
/// `UserDefaults.set` 遇到 `NSNull` 这类非属性列表值,抛的都是 Objective-C 异常,`try?` / `do-catch` 接不住。见 15 章决策 105。
public enum SafeSerialization {
    public enum Failure: Error { case notSerializable }

    /// 不合法返回 nil,不抛。
    public static func jsonData(_ object: Any, options: JSONSerialization.WritingOptions = []) -> Data? {
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        return try? JSONSerialization.data(withJSONObject: object, options: options)
    }

    /// 不合法抛 Swift 错误(`Failure.notSerializable`),给原来用 `try` 的地方。
    public static func jsonDataThrowing(_ object: Any, options: JSONSerialization.WritingOptions = []) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else { throw Failure.notSerializable }
        return try JSONSerialization.data(withJSONObject: object, options: options)
    }

    /// 这个值能不能放进 JSON(包成一元数组查,顶层必须是数组或字典)。
    public static func isJSONValue(_ value: Any) -> Bool {
        JSONSerialization.isValidJSONObject([value])
    }

    /// 这个值能不能写进 UserDefaults(属性列表类型,容器里也不能夹 `NSNull`)。
    public static func isPropertyListValue(_ value: Any) -> Bool {
        PropertyListSerialization.propertyList(value, isValidFor: .binary)
    }
}

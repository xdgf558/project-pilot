import Foundation

/// 对一份合法 JSON 做定点破坏,用来测解码的失败路径。
///
/// 抽出来是因为每个领域类型的测试都要做同样的事:编码一份合法数据,
/// 换掉其中一个键的值,断言解码报出**具体哪一类**错误。
/// 让每个测试文件各写一份私有拷贝,加到七个类型时就是七份。
///
/// 用 `JSONSerialization` 解析后再改,不是对文本做字符串手术 ——
/// 后者依赖 `.prettyPrinted` 的具体排版(`"key" : value` 之间的空格数),
/// 编码选项一变就悄悄失效,而失效的表现是「测试仍然绿」。
public enum JSONMutation {

    public enum Failure: Error, CustomStringConvertible {
        case notAnObject
        case keyNotFound(String, available: [String])

        public var description: String {
            switch self {
            case .notAnObject:
                return "顶层不是 JSON 对象,无法按键改写"
            case .keyNotFound(let key, let available):
                return "找不到键 \"\(key)\";现有的键:\(available.sorted().joined(separator: ", "))"
            }
        }
    }

    /// 把某个键的值换成任意 JSON 值(含类型不符的值,用来触发 typeMismatch)。
    ///
    /// 键不存在时**抛错而不是静默新增** —— 否则字段改名之后,
    /// 测试会变成往 JSON 里塞一个没人读的键,然后照常绿。
    public static func replacing(_ data: Data, key: String, with value: Any) throws -> Data {
        var object = try asObject(data)
        guard object[key] != nil else {
            throw Failure.keyNotFound(key, available: Array(object.keys))
        }
        object[key] = value
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// 删掉某个键,用来触发 keyNotFound。
    public static func removing(_ data: Data, key: String) throws -> Data {
        var object = try asObject(data)
        guard object.removeValue(forKey: key) != nil else {
            throw Failure.keyNotFound(key, available: Array(object.keys))
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private static func asObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.notAnObject
        }
        return object
    }
}

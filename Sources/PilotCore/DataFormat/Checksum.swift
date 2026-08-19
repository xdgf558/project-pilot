import Foundation

/// 内容校验和,用于**检测损坏**。
///
/// 不是防篡改。任何人都能改了内容再重算一遍校验和 ——
/// 本地单用户数据不需要防这个,防的是磁盘坏块、写到一半崩溃、
/// 和「文件看起来在那儿但内容是半截」这类情况(v0.2 §3 规则 10:
/// 损坏文件不能静默当作空数据)。
///
/// 用 FNV-1a 64 位而不是 CRC32 或 SHA:纯 Swift 二十行写得完、无依赖、
/// 输出确定。密码学哈希需要 CryptoKit,而 `PilotCore` 只允许
/// 标准库和 Foundation(P0-02)。
public struct Checksum: Sendable, Hashable, Codable, CustomStringConvertible {
    public let value: UInt64

    public init(value: UInt64) {
        self.value = value
    }

    /// 对一段字节计算校验和。
    public init(hashing data: Data) {
        // FNV-1a 64:offset basis 与 prime 是该算法的固定常数。
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01B3
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        self.value = hash
    }

    /// 十六进制表示,固定 16 位宽 —— 写进 JSON 的是这个,不是十进制数字,
    /// 因为 `UInt64` 超出 JSON 数字能精确表达的范围。
    public var description: String {
        String(format: "%016llx", value)
    }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard text.count == 16, let parsed = UInt64(text, radix: 16) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "校验和必须是 16 位十六进制字符串,实际得到:\(text)"
            )
        }
        self.value = parsed
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

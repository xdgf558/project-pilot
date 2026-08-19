import Foundation
import Testing
import PilotCore

@Suite("Checksum")
struct ChecksumTests {

    /// FNV-1a 64 规范公布的测试向量。
    ///
    /// 只测空输入是不够的 —— 空输入不经过乘法,把 prime 改掉也检测不出来。
    /// 实测过:单独留空输入那条时,故意改 prime 零条测试会红。
    /// 算法一旦悄悄变了,所有已存的校验和全部失效,而且没有任何东西会报错。
    @Test(
        "对上 FNV-1a 64 的官方测试向量",
        arguments: [
            (Data(), UInt64(0xcbf2_9ce4_8422_2325)),
            (Data("a".utf8), UInt64(0xaf63_dc4c_8601_ec8c)),
            (Data("foobar".utf8), UInt64(0x8594_4171_f739_67e8)),
        ]
    )
    func matchesPublishedVectors(_ input: Data, _ expected: UInt64) {
        #expect(Checksum(hashing: input).value == expected)
    }

    @Test("同样的输入得到同样的校验和")
    func isDeterministic() {
        let payload = Data("state.json 的内容".utf8)
        #expect(Checksum(hashing: payload) == Checksum(hashing: payload))
    }

    @Test("改一个比特就会变")
    func detectsSingleBitFlip() {
        var bytes = Data("revision: 42".utf8)
        let before = Checksum(hashing: bytes)
        bytes[0] ^= 0x01
        #expect(Checksum(hashing: bytes) != before)
    }

    @Test("字节顺序不同结果不同")
    func isOrderSensitive() {
        // 简单求和式的校验和在这里会漏 —— 顺序敏感是必须的,
        // 否则字段被调换位置检测不出来。
        #expect(Checksum(hashing: Data([1, 2, 3])) != Checksum(hashing: Data([3, 2, 1])))
    }

    @Test("编码成 16 位十六进制字符串")
    func encodesAsFixedWidthHex() throws {
        let data = try JSONEncoder().encode(Checksum(value: 0xff))
        // 不用 JSON 数字:UInt64 超出 JSON 数字能精确表达的范围,
        // 走一趟 Double 就可能丢低位。
        #expect(String(data: data, encoding: .utf8) == "\"00000000000000ff\"")
    }

    @Test("往返相等")
    func roundTrips() throws {
        let original = Checksum(hashing: Data("x".utf8))
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(Checksum.self, from: data) == original)
    }

    @Test("长度不对的十六进制串解码失败", arguments: ["\"abc\"", "\"0123456789abcdef0\"", "\"\""])
    func rejectsWrongLength(_ text: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Checksum.self, from: Data(text.utf8))
        }
    }

    @Test("非十六进制字符解码失败")
    func rejectsNonHexadecimal() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Checksum.self, from: Data("\"zzzzzzzzzzzzzzzz\"".utf8))
        }
    }
}

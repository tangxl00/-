//
//  JsonValue.swift
//  ReaderCore
//
//  与后端无关的通用 JSON 值模型。legado 的规则求值需要在
//  「字符串 / JSON / DOM」三种源之间来回转换，这里用一个
//  enum 承载 JSON 这一侧，避免上层到处传 [String: Any]。
//

import Foundation

public enum JsonValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JsonValue])
    case object([String: JsonValue])
}

public extension JsonValue {
    /// 从 JSONSerialization 的产物转换。
    static func from(_ any: Any) -> JsonValue {
        switch any {
        case is NSNull:
            return .null
        case let n as NSNumber:
            // Bool 在 NSNumber 桥接里也会命中，先用 CFTypeID 区分
            // JSONSerialization 把 true/false 桥接成 NSNumber(char 型)，
            // 用 objCType 区分布尔与数值（Linux corelibs 没有 CFGetTypeID）。
            if String(cString: n.objCType) == "c", n.intValue == 0 || n.intValue == 1 {
                return .bool(n.boolValue)
            }
            return .number(n.doubleValue)
        case let s as String:
            return .string(s)
        case let a as [Any]:
            return .array(a.map(JsonValue.from))
        case let d as [String: Any]:
            return .object(d.mapValues(JsonValue.from))
        case let v as JsonValue:
            return v
        default:
            return .string(String(describing: any))
        }
    }

    /// 解析 JSON 文本；失败返回 nil（不抛错，因为规则求值里「源不是 JSON」是常态）。
    static func parse(_ text: String) -> JsonValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return JsonValue.from(obj)
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// 单值取文本。对象 / 数组返回紧凑 JSON，便于后续再解析。
    var text: String {
        switch self {
        case .null: return ""
        case .bool(let b): return b ? "true" : "false"
        case .number(let d):
            if d == d.rounded(), abs(d) < 1e15 {
                return String(Int64(d))
            }
            return String(d)
        case .string(let s): return s
        case .array(let a):
            return JsonValue.encodeCompact(.array(a)) ?? ""
        case .object(let o):
            return JsonValue.encodeCompact(.object(o)) ?? ""
        }
    }

    /// 列表化：数组直接展开，其它包成单元素（空值返回空数组）。
    var flattened: [JsonValue] {
        switch self {
        case .array(let a): return a
        case .null: return []
        default: return [self]
        }
    }

    static func encodeCompact(_ value: JsonValue) -> String? {
        guard let data = try? JSONEncoder().encode(Box(value)),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    /// JSONEncoder 只能直接编码 Encodable 类型，这里包一层。
    private struct Box: Encodable {
        let value: JsonValue

        init(_ value: JsonValue) { self.value = value }

        func encode(to encoder: Encoder) throws {
            switch value {
            case .null: var c = encoder.singleValueContainer(); try c.encodeNil()
            case .bool(let b): var c = encoder.singleValueContainer(); try c.encode(b)
            case .number(let d): var c = encoder.singleValueContainer(); try c.encode(d)
            case .string(let s): var c = encoder.singleValueContainer(); try c.encode(s)
            case .array(let a):
                var c = encoder.unkeyedContainer()
                for item in a { try c.encode(Box(item)) }
            case .object(let o):
                var c = encoder.container(keyedBy: Key.self)
                for (k, v) in o.sorted(by: { $0.key < $1.key }) {
                    try c.encode(Box(v), forKey: Key(k))
                }
            }
        }

        struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(_ s: String) { stringValue = s }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }
    }
}

extension JsonValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let d = try? c.decode(Double.self) { self = .number(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JsonValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JsonValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        try Box(self).encode(to: encoder)
    }
}

/// Converts `Encodable` objects to `TemplateData`.
public final class TemplateDataEncoder {
    /// Create a new `TemplateDataEncoder`.
    public init() {}

    /// Encode an `Encodable` item to `TemplateData`.
    public func encode<E>(_ encodable: E, on worker: Worker, userInfo: [CodingUserInfoKey: Any] = [:]) throws -> Future<TemplateData> where E: Encodable {
        let encoder = _TemplateDataEncoder(context: .init(data: .dictionary([:]), on: worker), userInfo: userInfo)
        try encodable.encode(to: encoder)
        return encoder.context.data.resolve(on: worker)
    }
}

/// MARK: Private

/// A reference wrapper around `TemplateData`.
fileprivate final class PartialTemplateDataContext {
    /// The referenced `TemplateData`
    public var data: PartialTemplateData

    let eventLoop: EventLoop

    /// Create a new `TemplateDataContext`.
    public init(data: PartialTemplateData, on worker: Worker) {
        self.data = data
        self.eventLoop = worker.eventLoop
    }
}

/// Holds partially evaluated template data. This may still contain futures
/// that need to be resolved.
fileprivate enum PartialTemplateData: NestedData {
    case data(TemplateData)
    case future(Future<TemplateData>)
    case arr([PartialTemplateData])
    case dict([String: PartialTemplateData])

    func resolve(on worker: Worker) -> Future<TemplateData> {
        switch self {
        case .data(let data): return Future.map(on: worker) { data }
        case .future(let fut): return fut
        case .arr(let arr):
            return arr.map { $0.resolve(on: worker) }
                .flatten(on: worker)
                .map(to: TemplateData.self) { return .array($0) }
        case .dict(let dict):
            return dict.map { (key, val) in
                return val.resolve(on: worker).map(to: (String, TemplateData).self) { val in
                    return (key, val)
                }
            }.flatten(on: worker).map(to: TemplateData.self) { arr in
                var dict: [String: TemplateData] = [:]
                for (key, val) in arr {
                    dict[key] = val
                }
                return .dictionary(dict)
            }
        }
    }

    // MARK: NestedData

    /// See `NestedData`.
    static func dictionary(_ value: [String: PartialTemplateData]) -> PartialTemplateData {
        return .dict(value)
    }

    /// See `NestedData`.
    static func array(_ value: [PartialTemplateData]) -> PartialTemplateData {
        return .arr(value)
    }

    /// See `NestedData`.
    var dictionary: [String: PartialTemplateData]? {
        switch self {
        case .dict(let d): return d
        default: return nil
        }
    }

    /// See `NestedData`.
    var array: [PartialTemplateData]? {
        switch self {
        case .arr(let a): return a
        default: return nil
        }
    }
}

fileprivate final class _TemplateDataEncoder: Encoder, FutureEncoder {
    var codingPath: [CodingKey]
    var context: PartialTemplateDataContext
    var userInfo: [CodingUserInfoKey: Any]

    init(context: PartialTemplateDataContext, codingPath: [CodingKey] = [], userInfo: [CodingUserInfoKey: Any]) {
        self.context = context
        self.codingPath = codingPath
        self.userInfo = userInfo
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        let keyed = _TemplateDataKeyedEncoder<Key>(codingPath: codingPath, context: context, userInfo: userInfo)
        return KeyedEncodingContainer(keyed)
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        return _TemplateDataUnkeyedEncoder(codingPath: codingPath, context: context, userInfo: userInfo)
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        return _TemplateDataSingleValueEncoder(codingPath: codingPath, context: context)
    }

    func encodeFuture<E>(_ future: EventLoopFuture<E>) throws where E : Encodable {
        let userInfo = self.userInfo

        let future = future.flatMap(to: TemplateData.self) { encodable in
            return try TemplateDataEncoder().encode(encodable, on: self.context.eventLoop, userInfo: userInfo)
        }
        context.data.set(to: .future(future), at: codingPath)
    }
}

fileprivate final class _TemplateDataSingleValueEncoder: SingleValueEncodingContainer {
    var codingPath: [CodingKey]
    var context: PartialTemplateDataContext

    init(codingPath: [CodingKey], context: PartialTemplateDataContext) {
        self.codingPath = codingPath
        self.context = context
    }

    func encodeNil() throws {
        context.data.set(to: .data(.null), at: codingPath)
    }

    func encode<T>(_ value: T) throws where T: Encodable {
        guard let data = value as? TemplateDataRepresentable else {
            throw TemplateKitError(identifier: "templateData", reason: "`\(T.self)` does not conform to `TemplateDataRepresentable`.")
        }
        try context.data.set(to: .data(data.convertToTemplateData()), at: codingPath)
    }
}

fileprivate final class _TemplateDataKeyedEncoder<K>: KeyedEncodingContainerProtocol where K: CodingKey {
    typealias Key = K

    var codingPath: [CodingKey]
    var context: PartialTemplateDataContext
    var userInfo: [CodingUserInfoKey: Any]

    init(codingPath: [CodingKey], context: PartialTemplateDataContext, userInfo: [CodingUserInfoKey: Any]) {
        self.codingPath = codingPath
        self.context = context
        self.userInfo = userInfo
    }

    func superEncoder() -> Encoder {
        return _TemplateDataEncoder(context: context, codingPath: codingPath, userInfo: userInfo)
    }

    func encodeNil(forKey key: K) throws {
        context.data.set(to: .data(.null), at: codingPath + [key])
    }

    func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type, forKey key: K) -> KeyedEncodingContainer<NestedKey>
        where NestedKey : CodingKey
    {
        let container = _TemplateDataKeyedEncoder<NestedKey>(codingPath: codingPath + [key], context: context, userInfo: userInfo)
        return KeyedEncodingContainer(container)
    }

    func nestedUnkeyedContainer(forKey key: K) -> UnkeyedEncodingContainer {
        return _TemplateDataUnkeyedEncoder(codingPath: codingPath + [key], context: context, userInfo: userInfo)
    }

    func superEncoder(forKey key: K) -> Encoder {
        return _TemplateDataEncoder(context: context, codingPath: codingPath + [key], userInfo: userInfo)
    }

    func encode<T>(_ value: T, forKey key: K) throws where T: Encodable {
        if let data = value as? TemplateDataRepresentable {
            try context.data.set(to: .data(data.convertToTemplateData()), at: codingPath + [key])
        } else {
            
            let encoder = _TemplateDataEncoder(context: context, codingPath: codingPath + [key], userInfo: userInfo)
            try value.encode(to: encoder)
        }
    }
}


fileprivate final class _TemplateDataUnkeyedEncoder: UnkeyedEncodingContainer {
    var count: Int
    var codingPath: [CodingKey]
    var context: PartialTemplateDataContext
    var userInfo: [CodingUserInfoKey: Any]

    var index: CodingKey {
        defer { count += 1 }
        return BasicKey(count)
    }

    init(codingPath: [CodingKey], context: PartialTemplateDataContext, userInfo: [CodingUserInfoKey: Any]) {
        self.codingPath = codingPath
        self.context = context
        self.count = 0
        self.userInfo = userInfo
        context.data.set(to: .array([]), at: codingPath)
    }

    func encodeNil() throws {
        context.data.set(to: .data(.null), at: codingPath + [index])
    }

    func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey>
        where NestedKey: CodingKey
    {
        let container = _TemplateDataKeyedEncoder<NestedKey>(codingPath: codingPath + [index], context: context, userInfo: userInfo)
        return KeyedEncodingContainer(container)
    }

    func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        return _TemplateDataUnkeyedEncoder(codingPath: codingPath + [index], context: context, userInfo: userInfo)
    }

    func superEncoder() -> Encoder {
        return _TemplateDataEncoder(context: context, codingPath: codingPath + [index], userInfo: userInfo)
    }

    func encode<T>(_ value: T) throws where T: Encodable {
        let encoder = _TemplateDataEncoder(context: context, codingPath: codingPath + [index], userInfo: userInfo)
        try value.encode(to: encoder)
    }
}

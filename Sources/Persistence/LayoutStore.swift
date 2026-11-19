import Diagnostics
import Foundation

import CLaunchpadCore
public enum LayoutStoreError: Error {
    case directoryCreationFailed(Error)
    case encodingFailed(Error)
    case backupFailed(Error)
    case writeFailed(Error)
}

/// Reads/writes `LayoutDocument` with atomic writes and a last-known-good
/// backup, so a crash mid-write or a corrupted file never loses the previous
/// good state outright.
private final class LayoutReadBuffer {
    var data = Data()
}

private final class RustJSONDocument {
    let root: UnsafeMutableRawPointer
    private let compact: Bool
    init(data: Data) throws {
        let compactRoot = data.withUnsafeBytes { launchpad_compact_parse($0.bindMemory(to: UInt8.self).baseAddress, UInt($0.count)) }
        if let compactRoot {
            root = compactRoot
            compact = true
        } else {
            guard let fallback = data.withUnsafeBytes({ launchpad_json_parse($0.bindMemory(to: UInt8.self).baseAddress, UInt($0.count)) }) else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid JSON"))
            }
            root = fallback
            compact = false
        }
    }
    deinit {
        if compact { launchpad_compact_free(root) } else { launchpad_json_free(root) }
    }
    func kind(_ node: UnsafeRawPointer) -> Int32 { compact ? launchpad_compact_kind(node) : launchpad_json_kind(node) }
    func count(_ node: UnsafeRawPointer) -> UInt { compact ? launchpad_compact_count(node) : launchpad_json_count(node) }
    func item(_ node: UnsafeRawPointer, _ index: UInt) -> UnsafeRawPointer? { compact ? launchpad_compact_item(node, index) : launchpad_json_item(node, index) }
    func get(_ node: UnsafeRawPointer, _ key: UnsafePointer<UInt8>?, _ length: UInt) -> UnsafeRawPointer? {
        compact ? launchpad_compact_get(node, key, length) : launchpad_json_get(node, key, length)
    }
    func keys(_ node: UnsafeRawPointer, _ context: UnsafeMutableRawPointer?, _ callback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, UInt) -> Void) -> Int32 {
        compact ? launchpad_compact_keys(node, context, callback) : launchpad_json_keys(node, context, callback)
    }
    func string(_ node: UnsafeRawPointer, _ context: UnsafeMutableRawPointer?, _ callback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, UInt) -> Void) -> Int32 {
        compact ? launchpad_compact_string(node, context, callback) : launchpad_json_string(node, context, callback)
    }
    func bool(_ node: UnsafeRawPointer) -> Int32 { compact ? launchpad_compact_bool(node) : launchpad_json_bool(node) }
    func double(_ node: UnsafeRawPointer, _ value: UnsafeMutablePointer<Double>) -> Int32 { compact ? launchpad_compact_double(node, value) : launchpad_json_double(node, value) }
    func signed(_ node: UnsafeRawPointer, _ value: UnsafeMutablePointer<Int64>) -> Int32 { compact ? launchpad_compact_i64(node, value) : launchpad_json_i64(node, value) }
    func unsigned(_ node: UnsafeRawPointer, _ value: UnsafeMutablePointer<UInt64>) -> Int32 { compact ? launchpad_compact_u64(node, value) : launchpad_json_u64(node, value) }
}

private final class RustJSONStrings { var values: [String] = [] }

private struct RustJSONIndexKey: CodingKey {
    let intValue: Int?
    let stringValue: String
    init(_ index: Int) { intValue = index; stringValue = "Index \(index)" }
    init?(stringValue: String) { self.stringValue = stringValue; intValue = nil }
    init?(intValue: Int) { self.init(intValue) }
}

private final class RustJSONDecoder: Decoder, SingleValueDecodingContainer {
    let document: RustJSONDocument
    let node: UnsafeRawPointer
    let codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    init(document: RustJSONDocument, node: UnsafeRawPointer, codingPath: [CodingKey] = []) {
        self.document = document
        self.node = node
        self.codingPath = codingPath
    }

    func child(_ node: UnsafeRawPointer, key: CodingKey) -> RustJSONDecoder {
        RustJSONDecoder(document: document, node: node, codingPath: codingPath + [key])
    }

    func mismatch(_ type: Any.Type) -> DecodingError {
        .typeMismatch(type, .init(codingPath: codingPath, debugDescription: "Unexpected JSON value"))
    }

    func container<Key>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> where Key: CodingKey {
        guard document.kind(node) == 5 else { throw mismatch([String: Any].self) }
        return KeyedDecodingContainer(RustJSONKeyed<Key>(decoder: self))
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        guard document.kind(node) == 4 else { throw mismatch([Any].self) }
        return RustJSONUnkeyed(decoder: self)
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer { self }
    func decodeNil() -> Bool { document.kind(node) == 0 }
    func decode(_ type: Bool.Type) throws -> Bool {
        let value = document.bool(node)
        guard value >= 0 else { throw mismatch(type) }
        return value == 1
    }
    func decode(_ type: String.Type) throws -> String {
        let values = RustJSONStrings()
        let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, UInt) -> Void = { context, bytes, count in
            guard let context, let bytes, let count = Int(exactly: count) else { return }
            let value = String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
            Unmanaged<RustJSONStrings>.fromOpaque(context).takeUnretainedValue().values.append(value)
        }
        guard document.string(node, Unmanaged.passUnretained(values).toOpaque(), callback) == 1, let value = values.values.first else { throw mismatch(type) }
        return value
    }
    func decode(_ type: Double.Type) throws -> Double {
        var result = 0.0
        guard document.double(node, &result) == 1 else { throw mismatch(type) }
        return result
    }
    func decode(_ type: Float.Type) throws -> Float {
        let value = Float(try decode(Double.self))
        guard value.isFinite else { throw mismatch(type) }
        return value
    }
    private func signed<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        var value: Int64 = 0
        guard document.signed(node, &value) == 1, let result = T(exactly: value) else { throw mismatch(type) }
        return result
    }
    private func unsigned<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        var value: UInt64 = 0
        guard document.unsigned(node, &value) == 1, let result = T(exactly: value) else { throw mismatch(type) }
        return result
    }
    func decode(_ type: Int.Type) throws -> Int { try signed(type) }
    func decode(_ type: Int8.Type) throws -> Int8 { try signed(type) }
    func decode(_ type: Int16.Type) throws -> Int16 { try signed(type) }
    func decode(_ type: Int32.Type) throws -> Int32 { try signed(type) }
    func decode(_ type: Int64.Type) throws -> Int64 { try signed(type) }
    func decode(_ type: UInt.Type) throws -> UInt { try unsigned(type) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try unsigned(type) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try unsigned(type) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try unsigned(type) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try unsigned(type) }
    func decode<T>(_ type: T.Type) throws -> T where T: Decodable { try T(from: self) }
}

private struct RustJSONKeyed<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let decoder: RustJSONDecoder
    var codingPath: [CodingKey] { decoder.codingPath }
    var allKeys: [Key] {
        let values = RustJSONStrings()
        let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, UInt) -> Void = { context, bytes, count in
            guard let context, let bytes, let count = Int(exactly: count) else { return }
            let value = String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
            Unmanaged<RustJSONStrings>.fromOpaque(context).takeUnretainedValue().values.append(value)
        }
        _ = decoder.document.keys(decoder.node, Unmanaged.passUnretained(values).toOpaque(), callback)
        return values.values.compactMap(Key.init(stringValue:))
    }

    private func node(forKey key: Key) -> UnsafeRawPointer? {
        key.stringValue.withCString { pointer in
            decoder.document.get(decoder.node, UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self), UInt(key.stringValue.utf8.count))
        }
    }
    func contains(_ key: Key) -> Bool { node(forKey: key) != nil }
    private func child(_ key: Key) throws -> RustJSONDecoder {
        guard let node = node(forKey: key) else {
            throw DecodingError.keyNotFound(key, .init(codingPath: codingPath, debugDescription: "Missing JSON key"))
        }
        return decoder.child(node, key: key)
    }
    func decodeNil(forKey key: Key) throws -> Bool { try child(key).decodeNil() }
    private func value<T: Decodable>(_ type: T.Type, _ key: Key) throws -> T { try T(from: child(key)) }
    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try value(type, key) }
    func decode(_ type: String.Type, forKey key: Key) throws -> String { try value(type, key) }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double { try value(type, key) }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float { try value(type, key) }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try value(type, key) }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try value(type, key) }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try value(type, key) }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try value(type, key) }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try value(type, key) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try value(type, key) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try value(type, key) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try value(type, key) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try value(type, key) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try value(type, key) }
    func decode<T>(_ type: T.Type, forKey key: Key) throws -> T where T: Decodable { try value(type, key) }
    func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> where NestedKey: CodingKey {
        try child(key).container(keyedBy: type)
    }
    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer { try child(key).unkeyedContainer() }
    func superDecoder() throws -> Decoder { decoder }
    func superDecoder(forKey key: Key) throws -> Decoder { try child(key) }
}

private struct RustJSONUnkeyed: UnkeyedDecodingContainer {
    let decoder: RustJSONDecoder
    var codingPath: [CodingKey] { decoder.codingPath }
    var count: Int? { Int(exactly: decoder.document.count(decoder.node)) }
    var currentIndex = 0
    var isAtEnd: Bool { currentIndex >= (count ?? 0) }

    private func child() throws -> RustJSONDecoder {
        guard !isAtEnd, let node = decoder.document.item(decoder.node, UInt(currentIndex)) else {
            throw DecodingError.valueNotFound(Any.self, .init(codingPath: codingPath, debugDescription: "Unexpected end of array"))
        }
        return decoder.child(node, key: RustJSONIndexKey(currentIndex))
    }
    mutating func decodeNil() throws -> Bool {
        let isNil = try child().decodeNil()
        if isNil { currentIndex += 1 }
        return isNil
    }
    private mutating func value<T: Decodable>(_ type: T.Type) throws -> T {
        let result = try T(from: child())
        currentIndex += 1
        return result
    }
    mutating func decode(_ type: Bool.Type) throws -> Bool { try value(type) }
    mutating func decode(_ type: String.Type) throws -> String { try value(type) }
    mutating func decode(_ type: Double.Type) throws -> Double { try value(type) }
    mutating func decode(_ type: Float.Type) throws -> Float { try value(type) }
    mutating func decode(_ type: Int.Type) throws -> Int { try value(type) }
    mutating func decode(_ type: Int8.Type) throws -> Int8 { try value(type) }
    mutating func decode(_ type: Int16.Type) throws -> Int16 { try value(type) }
    mutating func decode(_ type: Int32.Type) throws -> Int32 { try value(type) }
    mutating func decode(_ type: Int64.Type) throws -> Int64 { try value(type) }
    mutating func decode(_ type: UInt.Type) throws -> UInt { try value(type) }
    mutating func decode(_ type: UInt8.Type) throws -> UInt8 { try value(type) }
    mutating func decode(_ type: UInt16.Type) throws -> UInt16 { try value(type) }
    mutating func decode(_ type: UInt32.Type) throws -> UInt32 { try value(type) }
    mutating func decode(_ type: UInt64.Type) throws -> UInt64 { try value(type) }
    mutating func decode<T>(_ type: T.Type) throws -> T where T: Decodable { try value(type) }
    mutating func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> where NestedKey: CodingKey {
        let result = try child().container(keyedBy: type)
        currentIndex += 1
        return result
    }
    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        let result = try child().unkeyedContainer()
        currentIndex += 1
        return result
    }
    mutating func superDecoder() throws -> Decoder {
        let result = try child()
        currentIndex += 1
        return result
    }
}

private final class RustJSONBuilder {
    let raw: UnsafeMutableRawPointer
    private(set) var failed = false
    init() { raw = launchpad_json_builder_new() }
    deinit { launchpad_json_builder_free(raw) }
    func check(_ result: Int32) { if result != 1 { failed = true } }
    func require(_ result: Int32, path: [CodingKey]) throws {
        guard result == 1 else {
            failed = true
            throw EncodingError.invalidValue("JSON", .init(codingPath: path, debugDescription: "Rust JSON encoding failed"))
        }
    }
    func key(_ value: String, parent: UInt) -> UInt {
        let index = value.withCString { pointer in
            launchpad_json_builder_key(raw, parent, UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self), UInt(value.utf8.count))
        }
        if index == UInt.max { failed = true }
        return index
    }
    func append(parent: UInt) -> UInt {
        let index = launchpad_json_builder_append(raw, parent)
        if index == UInt.max { failed = true }
        return index
    }
}

private final class RustJSONBytes { var data = Data() }

private final class RustJSONEncoder: Encoder, SingleValueEncodingContainer {
    let builder: RustJSONBuilder
    let node: UInt
    let codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }
    init(builder: RustJSONBuilder, node: UInt, codingPath: [CodingKey] = []) {
        self.builder = builder
        self.node = node
        self.codingPath = codingPath
    }
    func child(_ node: UInt, key: CodingKey) -> RustJSONEncoder { RustJSONEncoder(builder: builder, node: node, codingPath: codingPath + [key]) }
    func container<Key>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> where Key: CodingKey {
        builder.check(launchpad_json_builder_container(builder.raw, node, 5))
        return KeyedEncodingContainer(RustJSONEncodingKeyed<Key>(encoder: self))
    }
    func unkeyedContainer() -> UnkeyedEncodingContainer {
        builder.check(launchpad_json_builder_container(builder.raw, node, 4))
        return RustJSONEncodingUnkeyed(encoder: self)
    }
    func singleValueContainer() -> SingleValueEncodingContainer { self }
    func encodeNil() throws { try builder.require(launchpad_json_builder_null(builder.raw, node), path: codingPath) }
    func encode(_ value: Bool) throws { try builder.require(launchpad_json_builder_bool(builder.raw, node, value ? 1 : 0), path: codingPath) }
    func encode(_ value: String) throws {
        let status = value.withCString { pointer in
            launchpad_json_builder_string(builder.raw, node, UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self), UInt(value.utf8.count))
        }
        try builder.require(status, path: codingPath)
    }
    func encode(_ value: Double) throws { try builder.require(launchpad_json_builder_double(builder.raw, node, value), path: codingPath) }
    func encode(_ value: Float) throws { try encode(Double(value)) }
    private func signed<T: BinaryInteger>(_ value: T) throws {
        guard let value = Int64(exactly: value) else { throw EncodingError.invalidValue(value, .init(codingPath: codingPath, debugDescription: "Integer out of range")) }
        try builder.require(launchpad_json_builder_i64(builder.raw, node, value), path: codingPath)
    }
    private func unsigned<T: BinaryInteger>(_ value: T) throws {
        guard let value = UInt64(exactly: value) else { throw EncodingError.invalidValue(value, .init(codingPath: codingPath, debugDescription: "Integer out of range")) }
        try builder.require(launchpad_json_builder_u64(builder.raw, node, value), path: codingPath)
    }
    func encode(_ value: Int) throws { try signed(value) }
    func encode(_ value: Int8) throws { try signed(value) }
    func encode(_ value: Int16) throws { try signed(value) }
    func encode(_ value: Int32) throws { try signed(value) }
    func encode(_ value: Int64) throws { try signed(value) }
    func encode(_ value: UInt) throws { try unsigned(value) }
    func encode(_ value: UInt8) throws { try unsigned(value) }
    func encode(_ value: UInt16) throws { try unsigned(value) }
    func encode(_ value: UInt32) throws { try unsigned(value) }
    func encode(_ value: UInt64) throws { try unsigned(value) }
    func encode<T>(_ value: T) throws where T: Encodable {
        if let url = value as? URL { try encode(url.absoluteString); return }
        if let data = value as? Data { try encode(data.base64EncodedString()); return }
        try value.encode(to: self)
    }
}
private struct RustJSONEncodingKeyed<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let encoder: RustJSONEncoder
    var codingPath: [CodingKey] { encoder.codingPath }
    private func child(_ key: Key) -> RustJSONEncoder { encoder.child(encoder.builder.key(key.stringValue, parent: encoder.node), key: key) }
    mutating func encodeNil(forKey key: Key) throws { try child(key).encodeNil() }
    private func value<T: Encodable>(_ value: T, key: Key) throws { try child(key).encode(value) }
    mutating func encode(_ value: Bool, forKey key: Key) throws { try child(key).encode(value) }
    mutating func encode(_ value: String, forKey key: Key) throws { try child(key).encode(value) }
    mutating func encode(_ value: Double, forKey key: Key) throws { try child(key).encode(value) }
    mutating func encode(_ value: Float, forKey key: Key) throws { try child(key).encode(value) }
    mutating func encode(_ value: Int, forKey key: Key) throws { try child(key).encode(value) }
    mutating func encode(_ value: Int8, forKey key: Key) throws { try child(key).encode(value) }
    mutating func encode(_ value: Int16, forKey key: Key) throws { try child(key).encode(value) }
    mutating func encode(_ value: Int32, forKey key: Key) throws { try child(key).encode(value) }
    mutating func encode(_ value: Int64, forKey key: Key) throws { try child(key).encode(value) }
    mutating func encode(_ value: UInt, forKey key: Key) throws { try child(key).encode(value) }
    mutating func encode(_ value: UInt8, forKey key: Key) throws { try child(key).encode(value) }
    mutating func encode(_ value: UInt16, forKey key: Key) throws { try child(key).encode(value) }
    mutating func encode(_ value: UInt32, forKey key: Key) throws { try child(key).encode(value) }
    mutating func encode(_ value: UInt64, forKey key: Key) throws { try child(key).encode(value) }
    mutating func encode<T>(_ value: T, forKey key: Key) throws where T: Encodable { try self.value(value, key: key) }
    mutating func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> where NestedKey: CodingKey {
        child(key).container(keyedBy: type)
    }
    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer { child(key).unkeyedContainer() }
    mutating func superEncoder() -> Encoder {
        let key = RustJSONSuperKey()
        return encoder.child(encoder.builder.key(key.stringValue, parent: encoder.node), key: key)
    }
    mutating func superEncoder(forKey key: Key) -> Encoder { child(key) }
}

private struct RustJSONSuperKey: CodingKey {
    var stringValue: String { "super" }
    var intValue: Int? { nil }
    init() {}
    init?(stringValue: String) { guard stringValue == "super" else { return nil } }
    init?(intValue: Int) { return nil }
}

private struct RustJSONEncodingUnkeyed: UnkeyedEncodingContainer {
    let encoder: RustJSONEncoder
    var codingPath: [CodingKey] { encoder.codingPath }
    var count = 0
    private mutating func child() -> RustJSONEncoder {
        let key = RustJSONIndexKey(count)
        count += 1
        return encoder.child(encoder.builder.append(parent: encoder.node), key: key)
    }
    mutating func encodeNil() throws { try child().encodeNil() }
    mutating func encode(_ value: Bool) throws { try child().encode(value) }
    mutating func encode(_ value: String) throws { try child().encode(value) }
    mutating func encode(_ value: Double) throws { try child().encode(value) }
    mutating func encode(_ value: Float) throws { try child().encode(value) }
    mutating func encode(_ value: Int) throws { try child().encode(value) }
    mutating func encode(_ value: Int8) throws { try child().encode(value) }
    mutating func encode(_ value: Int16) throws { try child().encode(value) }
    mutating func encode(_ value: Int32) throws { try child().encode(value) }
    mutating func encode(_ value: Int64) throws { try child().encode(value) }
    mutating func encode(_ value: UInt) throws { try child().encode(value) }
    mutating func encode(_ value: UInt8) throws { try child().encode(value) }
    mutating func encode(_ value: UInt16) throws { try child().encode(value) }
    mutating func encode(_ value: UInt32) throws { try child().encode(value) }
    mutating func encode(_ value: UInt64) throws { try child().encode(value) }
    mutating func encode<T>(_ value: T) throws where T: Encodable { try child().encode(value) }
    mutating func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> where NestedKey: CodingKey { child().container(keyedBy: type) }
    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer { child().unkeyedContainer() }
    mutating func superEncoder() -> Encoder { child() }
}
public enum RustJSONCodec {
    public static func encode<T: Encodable>(_ document: T, prettyPrinted: Bool = false) throws -> Data {
        let builder = RustJSONBuilder()
        try RustJSONEncoder(builder: builder, node: 0).encode(document)
        guard !builder.failed else { throw EncodingError.invalidValue(document, .init(codingPath: [], debugDescription: "Rust JSON encoding failed")) }
        let output = RustJSONBytes()
        let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, UInt) -> Void = { context, bytes, count in
            guard let context, let bytes, let count = Int(exactly: count) else { return }
            Unmanaged<RustJSONBytes>.fromOpaque(context).takeUnretainedValue().data = Data(bytes: bytes, count: count)
        }
        let context = Unmanaged.passUnretained(output).toOpaque()
        // Rust streams the arena directly, avoiding a duplicate JSON tree.
        let status = prettyPrinted
            ? launchpad_json_builder_finish_pretty(builder.raw, context, callback)
            : launchpad_json_builder_finish(builder.raw, context, callback)
        guard status == 1 else {
            throw EncodingError.invalidValue(document, .init(codingPath: [], debugDescription: "Rust JSON encoding failed"))
        }
        return output.data
    }
}
public enum RustLayoutJSON {
    public static func encode(_ document: LayoutDocument) throws -> Data {
        try RustJSONCodec.encode(document)
    }

    public static func decode(_ data: Data) throws -> LayoutDocument {
        let document = try RustJSONDocument(data: data)
        return try LayoutDocument(from: RustJSONDecoder(document: document, node: UnsafeRawPointer(document.root)))
    }
}

public actor LayoutStore {
    private let primaryURL: URL
    private let backupURL: URL
    private let directoryCreationError: Error?

    public init(directory: URL? = nil) {
        let applicationSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        let base = directory ?? applicationSupport
            .appendingPathComponent("com.launchpadnative.app", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            self.directoryCreationError = nil
        } catch {
            DiagnosticsLog.persistence.error("Failed to create layout directory: \(error.localizedDescription, privacy: .public)")
            self.directoryCreationError = error
        }
        self.primaryURL = base.appendingPathComponent("layout.json")
        self.backupURL = base.appendingPathComponent("layout.lastknowngood.json")
    }

    /// Loads the current document, falling back to the last-known-good
    /// backup if the primary file is missing or fails to decode. Never
    /// throws — an unreadable store degrades to `.empty` rather than
    /// crashing the launcher.
    public func load() -> LayoutDocument {
        switch Self.decode(at: primaryURL) {
        case .success(let doc):
            return doc
        case .failure(let error):
            if FileManager.default.fileExists(atPath: primaryURL.path) {
                DiagnosticsLog.persistence.error("layout.json exists but failed to decode: \(error.localizedDescription, privacy: .public); falling back to last-known-good backup")
            }
        }

        switch Self.decode(at: backupURL) {
        case .success(let backup):
            return backup
        case .failure(let error):
            if FileManager.default.fileExists(atPath: backupURL.path) {
                DiagnosticsLog.persistence.error("layout.lastknowngood.json exists but failed to decode: \(error.localizedDescription, privacy: .public); returning empty layout")
            }
        }
        return .empty
    }

    /// Atomic write: the previous primary is promoted to the backup slot
    /// before the new one lands, so a write that fails partway never leaves
    /// the store worse off than before.
    public func save(_ document: LayoutDocument, updateBackup: Bool = true) throws {
        if let directoryCreationError {
            throw LayoutStoreError.directoryCreationFailed(directoryCreationError)
        }
        let data: Data
        do {
            data = try RustLayoutJSON.encode(document)
        } catch {
            throw LayoutStoreError.encodingFailed(error)
        }

        if FileManager.default.fileExists(atPath: primaryURL.path), case .failure = Self.decode(at: primaryURL) {
            quarantineUnreadablePrimary()
        } else if updateBackup && FileManager.default.fileExists(atPath: primaryURL.path) {
            do {
                let previous = try Self.readBytes(at: primaryURL)
                let result = backupURL.withUnsafeFileSystemRepresentation { path -> Int32 in
                    guard let path else { return 22 }
                    return previous.withUnsafeBytes { bytes in
                        launchpad_write_file_atomic(path, bytes.bindMemory(to: UInt8.self).baseAddress, UInt(bytes.count))
                    }
                }
                guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(result)) }
            } catch {
                DiagnosticsLog.persistence.error("Failed to prepare layout backup: \(error.localizedDescription, privacy: .public)")
                throw LayoutStoreError.backupFailed(error)
            }
        }

        let status = primaryURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return 22 }
            return data.withUnsafeBytes { bytes in
                launchpad_write_file_atomic(path, bytes.bindMemory(to: UInt8.self).baseAddress, UInt(bytes.count))
            }
        }
        guard status == 0 else {
            throw LayoutStoreError.writeFailed(NSError(domain: NSPOSIXErrorDomain, code: Int(status)))
        }
    }

    /// Moves a primary file that cannot be decoded out of the way, keeping it
    /// for inspection rather than deleting it.
    private func quarantineUnreadablePrimary() {
        let stamp = Int(Date().timeIntervalSince1970)
        let destination = primaryURL.deletingLastPathComponent()
            .appendingPathComponent("layout.unreadable-\(stamp)-\(UUID().uuidString.prefix(8)).json")
        do {
            try FileManager.default.moveItem(at: primaryURL, to: destination)
            DiagnosticsLog.persistence.error("layout.json could not be decoded; set it aside instead of promoting it to the backup")
        } catch {
            DiagnosticsLog.persistence.error("Could not set the unreadable layout.json aside: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Synchronous-result wrapper for runtime transactions that must know
    /// whether a restore point was durably written before applying an
    /// external side effect. Existing callers that use the throwing API keep
    /// their current behavior.
    public func saveResult(_ document: LayoutDocument) -> Bool {
        do {
            try save(document)
            return true
        } catch {
            DiagnosticsLog.persistence.error("Failed to save layout: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private static func readBytes(at url: URL) throws -> Data {
        let buffer = LayoutReadBuffer()
        let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, UInt) -> Void = { context, bytes, length in
            guard let context, let bytes, let count = Int(exactly: length) else { return }
            Unmanaged<LayoutReadBuffer>.fromOpaque(context).takeUnretainedValue().data = Data(bytes: bytes, count: count)
        }
        let status = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return 22 }
            return launchpad_read_file(path, Unmanaged.passUnretained(buffer).toOpaque(), callback)
        }
        guard status == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(status)) }
        return buffer.data
    }

    private static func decode(at url: URL) -> Result<LayoutDocument, Error> {
        do {
            return .success(try RustLayoutJSON.decode(readBytes(at: url)))
        } catch {
            return .failure(error)
        }
    }

    public func readBackup(at url: URL) throws -> Data {
        let buffer = LayoutReadBuffer()
        let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, UInt) -> Void = { context, bytes, length in
            guard let context, let bytes, let count = Int(exactly: length) else { return }
            Unmanaged<LayoutReadBuffer>.fromOpaque(context).takeUnretainedValue().data = Data(bytes: bytes, count: count)
        }
        let status = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return 22 }
            return launchpad_read_file_limited(path, 8 * 1024 * 1024, Unmanaged.passUnretained(buffer).toOpaque(), callback)
        }
        guard status == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(status)) }
        return buffer.data
    }

    public func writeBackup(_ data: Data, to url: URL) throws {
        guard data.count <= 8 * 1024 * 1024 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: 27)
        }
        let destination = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard destination != primaryURL.standardizedFileURL.resolvingSymlinksInPath().path,
              destination != backupURL.standardizedFileURL.resolvingSymlinksInPath().path else {
            throw NSError(domain: NSPOSIXErrorDomain, code: 22)
        }
        let status = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return 22 }
            return data.withUnsafeBytes { bytes in
                launchpad_write_file_atomic(path, bytes.bindMemory(to: UInt8.self).baseAddress, UInt(bytes.count))
            }
        }
        guard status == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(status)) }
    }
}

// The format-independent view of a tag: TagLib's `PropertyMap` (upper-case keys → string lists), which is what the
// Android app reads (`TagLib.getMetadata(...).propertyMap`) and writes (`TagLib.savePropertyMap`).

import Foundation

/// A TagLib-style property map: keys are upper-cased (ASCII only, like TagLib's `String::upper`), each key maps to
/// one or more values. Iteration and `keys` are in key order (TagLib's `PropertyMap` is a sorted map).
public struct TagProperties: Sendable, Hashable, Sequence, ExpressibleByDictionaryLiteral {
    private var storage: [String: [String]]

    public init() { storage = [:] }

    public init(_ dictionary: [String: [String]]) {
        storage = [:]
        for (k, v) in dictionary { insert(k, v) }
    }

    public init(dictionaryLiteral elements: (String, [String])...) {
        storage = [:]
        for (k, v) in elements { insert(k, v) }
    }

    /// Normalises a key the way TagLib does (ASCII upper-case).
    public static func normalize(_ key: String) -> String { TagText.asciiUpper(key) }

    /// The values for `key` (case-insensitive for ASCII). Setting nil removes the key; setting an empty list keeps
    /// the key with no values (TagLib then deletes the field when saving).
    public subscript(key: String) -> [String]? {
        get { storage[Self.normalize(key)] }
        set { storage[Self.normalize(key)] = newValue }
    }

    /// The first value for `key`, if any.
    public func first(_ key: String) -> String? { storage[Self.normalize(key)]?.first }

    /// TagLib `PropertyMap::insert`: appends `values` to the key's list (creating it).
    public mutating func insert(_ key: String, _ values: [String]) {
        storage[Self.normalize(key), default: []].append(contentsOf: values)
    }

    /// Removes `key`.
    public mutating func remove(_ key: String) { storage[Self.normalize(key)] = nil }

    /// Whether `key` is present.
    public func contains(_ key: String) -> Bool { storage[Self.normalize(key)] != nil }

    /// TagLib `PropertyMap::contains(const PropertyMap&)`: every key of `other` is present here with equal values.
    public func contains(_ other: TagProperties) -> Bool {
        for (k, v) in other.storage where storage[k] != v { return false }
        return true
    }

    /// TagLib `PropertyMap::erase(const PropertyMap&)`: removes every key of `other`.
    public mutating func erase(_ other: TagProperties) {
        for k in other.storage.keys { storage[k] = nil }
    }

    /// Sorted keys.
    public var keys: [String] { storage.keys.sorted(by: Self.keyOrder) }

    public var isEmpty: Bool { storage.isEmpty }
    public var count: Int { storage.count }

    /// The underlying dictionary (keys already normalised).
    public var dictionary: [String: [String]] { storage }

    public func makeIterator() -> IndexingIterator<[(key: String, values: [String])]> {
        keys.map { (key: $0, values: storage[$0]!) }.makeIterator()
    }

    /// TagLib orders keys by code point.
    static func keyOrder(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars)
    }
}

/// An embedded picture (ID3v2 `APIC`/`PIC`, FLAC `PICTURE` block or Vorbis `METADATA_BLOCK_PICTURE`, MP4 `covr`).
/// Mirrors TagLib's picture complex property, which the Android app reads through `TagLib.getPictures`.
public struct TagPicture: Sendable, Hashable {
    public var data: Data
    public var mimeType: String
    public var description: String
    /// The ID3v2/FLAC picture type (3 = front cover).
    public var pictureType: UInt8
    /// FLAC/Vorbis only (0 when unknown).
    public var width: UInt32
    public var height: UInt32
    public var colorDepth: UInt32
    public var indexedColors: UInt32

    public init(data: Data, mimeType: String, description: String = "", pictureType: UInt8 = TagPicture.frontCover,
                width: UInt32 = 0, height: UInt32 = 0, colorDepth: UInt32 = 0, indexedColors: UInt32 = 0) {
        self.data = data
        self.mimeType = mimeType
        self.description = description
        self.pictureType = pictureType
        self.width = width
        self.height = height
        self.colorDepth = colorDepth
        self.indexedColors = indexedColors
    }

    /// Picture type 3.
    public static let frontCover: UInt8 = 3

    /// TagLib's names for the picture types (the `pictureType` string Android passes to `TagLib.savePictures`).
    public static let typeNames: [String] = [
        "Other", "File Icon", "Other File Icon", "Front Cover", "Back Cover", "Leaflet Page", "Media", "Lead Artist",
        "Artist", "Conductor", "Band", "Composer", "Lyricist", "Recording Location", "During Recording",
        "During Performance", "Movie Screen Capture", "Colored Fish", "Illustration", "Band Logo", "Publisher Logo",
    ]

    /// The TagLib name of `pictureType` ("Other" when out of range).
    public var typeName: String { Int(pictureType) < Self.typeNames.count ? Self.typeNames[Int(pictureType)] : "Other" }

    /// The picture type for a TagLib name (`"Front Cover"` → 3); unknown names map to 0 ("Other").
    public static func type(named name: String) -> UInt8 {
        UInt8(typeNames.firstIndex(of: name) ?? 0)
    }
}

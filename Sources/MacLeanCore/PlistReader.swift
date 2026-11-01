import Foundation

public enum PlistReader {
    public static func dictionary(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil))
            as? [String: Any]
    }

    public static func string(_ key: String, in dictionary: [String: Any]) -> String? {
        dictionary[key] as? String
    }

    public static func strings(_ key: String, in dictionary: [String: Any]) -> [String] {
        dictionary[key] as? [String] ?? []
    }
}

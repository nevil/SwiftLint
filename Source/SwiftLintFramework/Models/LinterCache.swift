//
//  LinterCache.swift
//  SwiftLint
//
//  Created by Marcelo Fabri on 12/27/16.
//  Copyright © 2016 Realm. All rights reserved.
//

import Foundation
import SourceKittenFramework

internal enum LinterCacheError: Error {
    case invalidFormat
    case noLocation
}

public final class LinterCache {
    private var readCache = [String: Any]()
    private var writeCache = [String: Any]()
    private let lock = NSLock()
    internal let fileManager: LintableFileManager
    private let location: URL?

    internal init(fileManager: LintableFileManager = FileManager.default) {
        location = nil
        self.fileManager = fileManager
    }

    internal init(cache: Any, fileManager: LintableFileManager = FileManager.default) throws {
        guard let dictionary = cache as? [String: Any] else {
            throw LinterCacheError.invalidFormat
        }

        self.readCache = dictionary
        location = nil
        self.fileManager = fileManager
    }

    public init(configuration: Configuration,
                fileManager: LintableFileManager = FileManager.default) {
        location = configuration.cacheURL
        if let data = try? Data(contentsOf: location!),
            let json = try? JSONSerialization.jsonObject(with: data) {
            readCache = (json as? [String: Any]) ?? [:]
        }
        self.fileManager = fileManager
    }

    internal func cache(violations: [StyleViolation], forFile file: String, configuration: Configuration) {
        guard let lastModification = fileManager.modificationDate(forFileAtPath: file) else {
            return
        }

        let configurationDescription = configuration.cacheDescription

        lock.lock()
        var filesCache = (writeCache[configurationDescription] as? [String: Any]) ?? [:]
        filesCache[file] = [
            Key.violations.rawValue: violations.map(dictionary(for:)),
            Key.lastModification.rawValue: lastModification.timeIntervalSinceReferenceDate
        ]
        writeCache[configurationDescription] = filesCache
        lock.unlock()
    }

    internal func violations(forFile file: String, configuration: Configuration) -> [StyleViolation]? {
        guard let lastModification = fileManager.modificationDate(forFileAtPath: file) else {
            return nil
        }

        let configurationDescription = configuration.cacheDescription

        guard let filesCache = readCache[configurationDescription] as? [String: Any],
            let entry = filesCache[file] as? [String: Any],
            let cacheLastModification = entry[Key.lastModification.rawValue] as? TimeInterval,
            cacheLastModification == lastModification.timeIntervalSinceReferenceDate,
            let violations = entry[Key.violations.rawValue] as? [[String: Any]] else {
                return nil
        }

        return violations.flatMap { StyleViolation.from(cache: $0, file: file) }
    }

    public func save() throws {
        guard let url = location else {
            throw LinterCacheError.noLocation
        }
        guard !writeCache.isEmpty else {
            return
        }
        lock.lock()
        let cache = mergeCaches()
        lock.unlock()

        let json = toJSON(cache)
        try json.write(to: url, atomically: true, encoding: .utf8)
    }

    internal func flushWriteCacheToReadCache() {
        lock.lock()
        readCache = mergeCaches()
        writeCache = [:]
        lock.unlock()
    }

    private func mergeCaches() -> [String: Any] {
        var cache = readCache
        for (key, value) in writeCache {
            var filesCache = (cache[key] as? [String: Any]) ?? [:]
            for (file, fileCache) in (value as? [String: Any]) ?? [:] {
                filesCache[file] = fileCache
            }
            cache[key] = filesCache
        }
        return cache
    }

    private func dictionary(for violation: StyleViolation) -> [String: Any] {
        return [
            Key.line.rawValue: violation.location.line ?? NSNull() as Any,
            Key.character.rawValue: violation.location.character ?? NSNull() as Any,
            Key.severity.rawValue: violation.severity.rawValue,
            Key.type.rawValue: violation.ruleDescription.name,
            Key.ruleID.rawValue: violation.ruleDescription.identifier,
            Key.reason.rawValue: violation.reason
        ]
    }
}

extension LinterCache {
    fileprivate enum Key: String {
        case character
        case configuration
        case lastModification = "last_modification"
        case line
        case reason
        case ruleID = "rule_id"
        case severity
        case type
        case violations
    }
}

extension StyleViolation {
    fileprivate static func from(cache: [String: Any], file: String) -> StyleViolation? {
        guard let severityString = (cache[LinterCache.Key.severity.rawValue] as? String),
            let severity = ViolationSeverity(rawValue: severityString),
            let name = cache[LinterCache.Key.type.rawValue] as? String,
            let ruleID = cache[LinterCache.Key.ruleID.rawValue] as? String,
            let reason = cache[LinterCache.Key.reason.rawValue] as? String else {
                return nil
        }

        let line = cache[LinterCache.Key.line.rawValue] as? Int
        let character = cache[LinterCache.Key.character.rawValue] as? Int
        return StyleViolation(ruleDescription: RuleDescription(identifier: ruleID, name: name, description: reason),
                              severity: severity,
                              location: Location(file: file, line: line, character: character),
                              reason: reason)
    }
}

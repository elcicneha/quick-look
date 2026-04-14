//
//  OnigScanner.swift
//  QuickLookCodeShared
//
//  Swift wrapper around the vendored oniguruma C library, exposed to
//  JavaScriptCore as `globalThis.onigLib` so vscode-textmate uses real
//  oniguruma (not our JS regex approximation) for pattern matching.
//
//  IOnigLib interface implemented:
//
//      createOnigScanner(patterns: string[]) -> OnigScanner
//      createOnigString(str: string)         -> OnigString
//
//      OnigScanner.findNextMatchSync(string, startPosition) -> IOnigMatch | null
//      OnigScanner.dispose()
//      OnigString.content : string
//      OnigString.dispose()
//
//  Encoding strategy: we use `ONIG_ENCODING_UTF16_LE`, which matches the
//  in-memory layout of JavaScript strings on every Apple platform
//  (arm64 and x86_64 are both little-endian). A UTF-16 code unit offset
//  — the unit JS strings are indexed by — maps to an oniguruma byte
//  offset by multiplying by 2. No UTF-8 ↔ UTF-16 conversion is needed.
//

import Foundation
import JavaScriptCore
import COniguruma

// MARK: - One-time oniguruma initialization

private enum OnigRuntime {
    private static let initialized: Bool = {
        var encoding = onigshim_utf16le()
        _ = withUnsafeMutablePointer(to: &encoding) { ptr in
            onig_initialize(ptr, 1)
        }
        return true
    }()

    static func ensure() { _ = initialized }
}

// MARK: - JSExport protocols

@objc public protocol OnigScannerJSExport: JSExport {
    func findNextMatchSync(_ string: JSValue, _ startPosition: JSValue) -> [String: Any]?
    func dispose()
}

@objc public protocol OnigStringJSExport: JSExport {
    var content: String { get }
    func dispose()
}

// MARK: - OnigString

/// Caches a JS string's UTF-16 buffer so repeated searches against the same
/// string avoid re-copying on every call.
@objc public final class OnigString: NSObject, OnigStringJSExport {
    @objc public let content: String
    fileprivate let utf16Units: [UInt16]

    @objc public init(content: String) {
        self.content = content
        self.utf16Units = Array(content.utf16)
        super.init()
    }

    @objc public func dispose() {
        // utf16Units is released when the object is.
    }
}

// MARK: - OnigScanner

@objc public final class OnigScanner: NSObject, OnigScannerJSExport {

    /// One compiled regex per source pattern. `nil` entries represent patterns
    /// that failed to compile — they are silently skipped at search time,
    /// mirroring vscode-oniguruma's behaviour on invalid input.
    private var regexes: [OpaquePointer?]
    private var disposed = false

    @objc public init(patterns: [String]) {
        OnigRuntime.ensure()
        self.regexes = patterns.map { Self.compile(pattern: $0) }
        super.init()
    }

    deinit { dispose() }

    @objc public func dispose() {
        if disposed { return }
        disposed = true
        for r in regexes {
            if let r { onig_free(r) }
        }
        regexes.removeAll()
    }

    // MARK: Compilation

    private static func compile(pattern: String) -> OpaquePointer? {
        let units = Array(pattern.utf16)
        return units.withUnsafeBufferPointer { buf -> OpaquePointer? in
            guard let base = buf.baseAddress else { return nil }
            let raw = UnsafeRawPointer(base)
            let bytes = raw.assumingMemoryBound(to: OnigUChar.self)
            let byteLen = buf.count * MemoryLayout<UInt16>.size

            var reg: OpaquePointer? = nil
            var einfo = OnigErrorInfo()
            let status = onig_new(
                &reg,
                bytes,
                bytes.advanced(by: byteLen),
                OnigOptionType(ONIG_OPTION_CAPTURE_GROUP),
                onigshim_utf16le(),
                onigshim_syntax_oniguruma(),
                &einfo
            )
            if status != ONIG_NORMAL {
                if reg != nil { onig_free(reg) }
                return nil
            }
            return reg
        }
    }

    // MARK: Search

    @objc public func findNextMatchSync(_ string: JSValue, _ startPosition: JSValue) -> [String: Any]? {
        if disposed || regexes.isEmpty { return nil }

        // Accept either a JS string or an OnigString wrapper.
        let utf16Units: [UInt16]
        if let wrapped = string.toObject() as? OnigString {
            utf16Units = wrapped.utf16Units
        } else {
            utf16Units = Array((string.toString() ?? "").utf16)
        }

        let startUnit = max(0, Int(startPosition.toInt32()))
        if startUnit > utf16Units.count { return nil }

        guard let region = onig_region_new() else { return nil }
        defer { onig_region_free(region, 1) }

        var bestPatternIdx = -1
        var bestStartUnit = Int.max
        var bestCaptures: [[String: Int]] = []

        utf16Units.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            let raw = UnsafeRawPointer(base)
            let bytes = raw.assumingMemoryBound(to: OnigUChar.self)
            let totalBytes = buf.count * MemoryLayout<UInt16>.size
            let strBegin = bytes
            let strEnd = bytes.advanced(by: totalBytes)
            let searchStart = bytes.advanced(by: startUnit * MemoryLayout<UInt16>.size)

            for (i, reg) in regexes.enumerated() {
                guard let reg else { continue }

                onig_region_clear(region)
                let result = onig_search(
                    reg,
                    strBegin,
                    strEnd,
                    searchStart,
                    strEnd,
                    region,
                    OnigOptionType(ONIG_OPTION_NONE)
                )

                // ONIG_MISMATCH (-1) or any negative = no match / error. Skip.
                if result < 0 { continue }

                let matchStartUnit = Int(result) / MemoryLayout<UInt16>.size
                if matchStartUnit < bestStartUnit {
                    bestStartUnit = matchStartUnit
                    bestPatternIdx = i
                    bestCaptures = extractCaptures(region: region)
                }
            }
        }

        if bestPatternIdx < 0 { return nil }
        return [
            "index": bestPatternIdx,
            "captureIndices": bestCaptures,
        ]
    }

    private func extractCaptures(region: UnsafeMutablePointer<OnigRegion>) -> [[String: Int]] {
        let numRegs = Int(region.pointee.num_regs)
        guard numRegs > 0,
              let begPtr = region.pointee.beg,
              let endPtr = region.pointee.end
        else { return [] }

        var result: [[String: Int]] = []
        result.reserveCapacity(numRegs)
        for i in 0..<numRegs {
            let begByte = Int(begPtr[i])
            let endByte = Int(endPtr[i])
            if begByte < 0 || endByte < 0 {
                result.append(["start": 0, "end": 0, "length": 0])
                continue
            }
            let start = begByte / MemoryLayout<UInt16>.size
            let end = endByte / MemoryLayout<UInt16>.size
            result.append(["start": start, "end": end, "length": end - start])
        }
        return result
    }
}

// MARK: - JSContext installer

/// Installs `globalThis.onigLib = { createOnigScanner, createOnigString }` into
/// the given `JSContext`. Call once, before loading the tokenizer bundle.
public enum OnigJSBridge {
    public static func install(in context: JSContext) {
        let createScanner: @convention(block) ([String]) -> OnigScanner = { patterns in
            OnigScanner(patterns: patterns)
        }
        let createString: @convention(block) (String) -> OnigString = { str in
            OnigString(content: str)
        }

        context.setObject(createScanner, forKeyedSubscript: "__createOnigScanner" as NSString)
        context.setObject(createString,  forKeyedSubscript: "__createOnigString"  as NSString)

        context.evaluateScript("""
        globalThis.onigLib = {
            createOnigScanner: (patterns) => globalThis.__createOnigScanner(patterns),
            createOnigString:  (s)        => globalThis.__createOnigString(s),
        };
        """)
    }
}

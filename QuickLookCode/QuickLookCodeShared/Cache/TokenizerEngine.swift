//
//  TokenizerEngine.swift
//  QuickLookCodeShared
//
//  A process-lifetime singleton that owns one JSContext running vscode-textmate.
//  The 61 KB tokenizer-jsc.js bundle is evaluated once; oniguruma is installed once.
//  Between calls the actor only re-runs `initGrammar` when the language or theme changes,
//  and skips it entirely when the same language is tokenized twice in a row (e.g. browsing
//  a folder of .py files).
//
//  Thread-safety: Swift actor isolation serialises all access automatically.
//

import Foundation
import JavaScriptCore

actor TokenizerEngine {

    static let shared = TokenizerEngine()

    private let context: JSContext

    // Track what's currently loaded so we can skip initGrammar on re-use.
    private var loadedLanguage: String?
    private var loadedThemeJSON: String?

    private init() {
        let ctx = JSContext()!
        ctx.exceptionHandler = { _, exception in
            guard let msg = exception?.toString() else { return }
            NSLog("[QuickLookCode] JSC exception: %@", msg)
        }

        // Bridge console.error → NSLog.
        let nslogBlock: @convention(block) (String) -> Void = { msg in
            NSLog("[QuickLookCode] JS: %@", msg)
        }
        ctx.setObject(nslogBlock, forKeyedSubscript: "__nslog" as NSString)
        ctx.evaluateScript(
            "console.error = function() { try { __nslog(Array.prototype.slice.call(arguments).join(' ')); } catch(e) {} };"
        )

        // JSC has no `window`; shim it so the IIFE bundle works.
        ctx.evaluateScript("var window = globalThis;")

        // Install native oniguruma BEFORE loading the bundle.
        OnigJSBridge.install(in: ctx)

        // Load + evaluate the vscode-textmate bundle (once for the process lifetime).
        let bundle = Bundle(for: BundleAnchor.self)
        if let url = bundle.url(forResource: "tokenizer-jsc", withExtension: "js"),
           let script = try? String(contentsOf: url, encoding: .utf8) {
            ctx.evaluateScript(script)
        } else {
            NSLog("[QuickLookCode] TokenizerEngine: tokenizer-jsc.js not found — run `pnpm run build` in tokenizer/")
        }

        self.context = ctx
    }

    // MARK: - API

    /// Tokenizes `code`. Calls `initGrammar` only when language or theme changes.
    func tokenize(
        code: String,
        language: String,
        grammarJSON: String,
        siblingGrammarsJSON: String,
        injectionsJSON: String,
        themeJSON: String
    ) -> [[SourceCodeRenderer.RawToken]] {
        if loadedLanguage != language || loadedThemeJSON != themeJSON {
            context.objectForKeyedSubscript("initGrammar")?
                .call(withArguments: [grammarJSON, themeJSON, siblingGrammarsJSON, injectionsJSON])
            loadedLanguage = language
            loadedThemeJSON = themeJSON
        }

        guard let result = context.objectForKeyedSubscript("doTokenize")?.call(withArguments: [code]),
              !result.isNull, !result.isUndefined
        else { return [] }

        return SourceCodeRenderer.parseResult(result)
    }

    /// Clears cached grammar/theme state — call after a cache refresh so the next
    /// tokenize call re-runs initGrammar with the new theme.
    func invalidate() {
        loadedLanguage = nil
        loadedThemeJSON = nil
    }
}

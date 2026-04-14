/**
 * tokenizer-jsc.js — JavaScriptCore-compatible synchronous tokenizer
 *
 * Uses vscode-textmate's tokenizeLine2 to produce packed metadata, resolves
 * foreground colors via the registry's internal color map, and returns flat
 * {text, color, fontStyle} spans to Swift. This moves scope-to-color matching
 * (descendant/parent/exclusion selectors, specificity scoring) into the
 * library — identical to what VS Code itself does.
 *
 * Regex engine: `globalThis.onigLib` is provided by Swift before this bundle
 * is evaluated. It is backed by the vendored oniguruma C library (see
 * QuickLookCodeShared/Vendor/Oniguruma), so pattern matching is byte-for-byte
 * compatible with VS Code's tokenizer.
 *
 * Swift protocol:
 *   1. globalThis.initGrammar(grammarJSON: string, themeJSON: string)
 *   2. (JSC drains microtasks automatically after the call returns)
 *   3. globalThis.doTokenize(code: string)
 *        → Array<Array<{text, color, fontStyle}>>
 */

import { Registry, INITIAL } from "vscode-textmate";

// ---------------------------------------------------------------------------
// tokenizeLine2 metadata layout (vscode-textmate MetadataConsts)
// ---------------------------------------------------------------------------
//   bits  0-7   language id     (ignored here)
//   bits  8-9   token type      (ignored here)
//   bit  10     balanced bracket flag
//   bits 11-14  font style      (1=italic, 2=bold, 4=underline, 8=strikethrough)
//   bits 15-23  foreground index into color map
//   bits 24-31  background index into color map (ignored — we use theme.background)

const FONT_STYLE_OFFSET = 11;
const FOREGROUND_OFFSET = 15;
const FONT_STYLE_MASK = 0xF;
const FOREGROUND_MASK = 0x1FF;

// ---------------------------------------------------------------------------
// Two-step protocol globals
// ---------------------------------------------------------------------------

let _grammar = null;
let _colorMap = null;

globalThis.initGrammar = function initGrammar(grammarJSON, themeJSON) {
    _grammar = null;
    _colorMap = null;

    if (!globalThis.onigLib) {
        console.error("initGrammar: globalThis.onigLib not installed");
        return;
    }

    let grammarDef;
    try {
        grammarDef = JSON.parse(grammarJSON);
    } catch (e) {
        console.error("initGrammar: failed to parse grammarJSON: " + e.message);
        return;
    }

    let theme = null;
    if (themeJSON) {
        try {
            theme = JSON.parse(themeJSON);
        } catch (e) {
            console.error("initGrammar: failed to parse themeJSON: " + e.message);
        }
    }

    const scopeName = grammarDef.scopeName;

    const registry = new Registry({
        onigLib: Promise.resolve(globalThis.onigLib),
        loadGrammar: (name) =>
            name === scopeName
                ? Promise.resolve(grammarDef)
                : Promise.resolve(null),
    });

    if (theme) {
        registry.setTheme(theme);
        _colorMap = registry.getColorMap();
    }

    // loadGrammar returns a Promise; JSC drains the microtask queue after this
    // call returns, so _grammar is set before doTokenize runs.
    registry.loadGrammar(scopeName).then((g) => {
        _grammar = g;
    });
};

globalThis.doTokenize = function doTokenize(code) {
    if (!_grammar) return null;

    const lines = code.split("\n");
    let ruleStack = INITIAL;
    const result = [];

    for (const line of lines) {
        const { tokens, ruleStack: nextStack } = _grammar.tokenizeLine2(
            line,
            ruleStack
        );
        ruleStack = nextStack;

        const lineTokens = [];
        const len = tokens.length;
        for (let i = 0; i < len; i += 2) {
            const start = tokens[i];
            const metadata = tokens[i + 1];
            const end = i + 2 < len ? tokens[i + 2] : line.length;
            if (end <= start) continue;

            const fgIdx = (metadata >>> FOREGROUND_OFFSET) & FOREGROUND_MASK;
            const fsFlags = (metadata >>> FONT_STYLE_OFFSET) & FONT_STYLE_MASK;

            const color = (_colorMap && fgIdx > 0) ? (_colorMap[fgIdx] || null) : null;

            let fontStyle = null;
            if (fsFlags) {
                const parts = [];
                if (fsFlags & 1) parts.push("italic");
                if (fsFlags & 2) parts.push("bold");
                if (fsFlags & 4) parts.push("underline");
                if (fsFlags & 8) parts.push("strikethrough");
                fontStyle = parts.join(" ");
            }

            lineTokens.push({
                text: line.slice(start, end),
                color,
                fontStyle,
            });
        }

        result.push(lineTokens);
    }

    return result;
};

//
//  TokenMapper.swift
//  QuickLookCodeShared
//

import Foundation

/// Maps TextMate token scopes to theme colors using VS Code's matching algorithm.
public struct TokenMapper {

    public let theme: ThemeData

    public init(theme: ThemeData) {
        self.theme = theme
    }

    // MARK: - Public API

    public func color(forScopes tokenScopes: [String]) -> String? {
        for tokenScope in tokenScopes.reversed() {
            if let rule = bestRule(for: tokenScope), let fg = rule.foreground {
                return fg
            }
        }
        return nil
    }

    public func fontStyle(forScopes tokenScopes: [String]) -> String? {
        for tokenScope in tokenScopes.reversed() {
            if let rule = bestRule(for: tokenScope), let style = rule.fontStyle {
                return style
            }
        }
        return nil
    }

    // MARK: - Matching

    private func bestRule(for scope: String) -> TokenColorRule? {
        var bestRule: TokenColorRule?
        var bestLength = 0

        for rule in theme.tokenColors {
            for ruleScope in rule.scopes {
                guard scopeMatches(ruleScope: ruleScope, tokenScope: scope) else { continue }
                if ruleScope.count > bestLength {
                    bestLength = ruleScope.count
                    bestRule = rule
                }
            }
        }
        return bestRule
    }

    private func scopeMatches(ruleScope: String, tokenScope: String) -> Bool {
        guard tokenScope.hasPrefix(ruleScope) else { return false }
        if tokenScope.count == ruleScope.count { return true }
        let nextIndex = tokenScope.index(tokenScope.startIndex, offsetBy: ruleScope.count)
        return tokenScope[nextIndex] == "."
    }
}

//
//  PreviewProvider.swift
//  QuickLookCodeExtension
//
//  Created by Neha Gupta on 14/04/26.
//

import Cocoa
import Quartz
import UniformTypeIdentifiers

class PreviewProvider: QLPreviewProvider, QLPreviewingController {

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        let filename = url.lastPathComponent

        let html = """
        <!DOCTYPE html>
        <html>
        <body style="background:#1e1e1e;color:#d4d4d4;font-family:monospace;padding:20px;margin:0;">
        <h2 style="color:#9cdcfe;">QuickLookCode</h2>
        <p>File: \(filename)</p>
        <p style="color:#6a9955;">// Hello from QuickLookCode Extension — Phase 0 working!</p>
        </body>
        </html>
        """

        let reply = QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 800, height: 600)) { _ in
            return Data(html.utf8)
        }
        return reply
    }
}

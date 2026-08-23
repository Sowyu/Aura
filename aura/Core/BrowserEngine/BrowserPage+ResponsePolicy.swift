import Foundation
import WebKit

// MARK: - PDF viewer

// WebKit draws PDFs itself, and both of the things a PDF viewer has to support work
// against that view. Measured on macOS 27 beta with a standalone WKWebView harness, over
// http and over `file://`:
//
// - `find(_:configuration:)` reports `matchFound == true` for a string that is in the
//   document and false for one that is not, so `FindManager` needs no PDF-specific path.
// - `pageZoom` reads back what it was set to and changes what is drawn: snapshots of the
//   same page at 1.0 and at 2.5 differ. `SiteZoomController` drives the PDF view the same
//   way it drives a page, now that a file URL has a zoom key of its own.
//
// So there is no PDFKit fallback here. If a later WebKit drops either, this is the note
// to come back to.

// MARK: - Response policy

/// Whether a response is drawn in the tab or handed to the download flow.
enum BrowserResponseDisposition: Equatable {
    case inline
    case download
}

extension BrowserPage {
    /// The inline-or-download rule, as a plain function over what WebKit reports.
    ///
    /// The response's MIME type reaches the decision through `canShowMIMEType`, which is
    /// WebKit's own answer for it. Measured on macOS 27 beta with a WKWebView harness:
    /// `application/pdf`, `image/png`, `image/svg+xml`, `text/markdown`, `text/plain` and
    /// `text/html` all report true, over http and over `file://` alike, so a local PDF
    /// lands in WebKit's own viewer and a local zip (`application/zip`, false) goes down
    /// the download path instead of leaving a blank tab.
    ///
    /// A server can still force a download of something WebKit could draw by marking the
    /// response an attachment, which is why the header wins. Measured against a real HTTP
    /// response: `Content-Disposition: attachment` on a PDF arrives here with
    /// `canShowMIMEType` true and has to be turned into a download by this rule.
    /// Ported from Nook, `Nook/Models/Tab/Tab.swift` by Maciek Bagiński (GPL-3.0).
    static func responseDisposition(
        canShowMIMEType: Bool,
        contentDisposition: String?
    ) -> BrowserResponseDisposition {
        let isAttachment = contentDisposition?.lowercased().contains("attachment") ?? false
        return canShowMIMEType && !isAttachment ? .inline : .download
    }
}

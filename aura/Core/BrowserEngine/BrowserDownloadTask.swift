import Foundation
@preconcurrency import WebKit

final class BrowserDownloadTask: NSObject, WKDownloadDelegate {
    let id = UUID()
    var originalURL: URL
    var onDestinationRequest: ((URLResponse, String, @escaping (URL?) -> Void) -> Void)?
    var onRedirect: ((URL) -> Void)?
    var onFinish: (() -> Void)?
    /// The error plus WebKit's resume blob, when it produced one.
    var onFail: ((Error, Data?) -> Void)?

    /// Set when a failure carried resume data, so a retry can pick the transfer up
    /// instead of starting over.
    private(set) var resumeData: Data?

    private let download: WKDownload

    init(download: WKDownload, originalURL: URL) {
        self.download = download
        self.originalURL = originalURL
        super.init()
        self.download.delegate = self
    }

    var progress: Progress {
        download.progress
    }

    func cancel() {
        download.cancel()
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        if let onDestinationRequest {
            onDestinationRequest(response, suggestedFilename, completionHandler)
        } else {
            completionHandler(nil)
        }
    }

    func download(
        _ download: WKDownload,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest: URLRequest,
        decisionHandler: @escaping (WKDownload.RedirectPolicy) -> Void
    ) {
        if let url = newRequest.url {
            originalURL = url
            onRedirect?(url)
        }
        decisionHandler(.allow)
    }

    func downloadDidFinish(_ download: WKDownload) {
        onFinish?()
    }

    /// The three-argument form is the WKDownloadDelegate selector. The two-argument
    /// `download(_:didFailWithError:)` this replaces is not one, so WebKit never called
    /// it: a failed download stayed "downloading" for good and its 10 Hz progress timer
    /// ran until the app quit.
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        self.resumeData = resumeData
        onFail?(error, resumeData)
    }
}

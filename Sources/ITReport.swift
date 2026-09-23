import AppKit
import WebKit
import PDFKit

/// Turns a scan into a printable PDF. The report page lays itself out as US Letter pages; WebKit renders
/// each page on its own (one tall render would hit PDF's 14,400-point page limit) and they're joined.
final class ReportPDF: NSObject, WKNavigationDelegate {
    static let pageSize = CGSize(width: 612, height: 792)   // US Letter, in points
    private static var inFlight: [ReportPDF] = []           // keeps each renderer alive until it finishes

    private let report: [String: Any]
    private let completion: (Data?) -> Void
    private let webView: WKWebView

    static func render(_ report: [String: Any], uiDirectory: URL, completion: @escaping (Data?) -> Void) {
        let renderer = ReportPDF(report: report) { data in
            inFlight.removeAll { $0.webView.navigationDelegate == nil }
            completion(data)
        }
        inFlight.append(renderer)
        renderer.webView.loadFileURL(uiDirectory.appendingPathComponent("report.html"), allowingReadAccessTo: uiDirectory)
    }

    private init(report: [String: Any], completion: @escaping (Data?) -> Void) {
        self.report = report
        self.completion = completion
        webView = WKWebView(frame: NSRect(origin: .zero, size: ReportPDF.pageSize))
        super.init()
        webView.navigationDelegate = self
    }

    private func finish(_ data: Data?) {
        webView.navigationDelegate = nil
        completion(data)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.callAsyncJavaScript("return window.renderReport(report)", arguments: ["report": report], in: nil, in: .page) { [self] result in
            guard case .success(let value) = result, let pages = (value as? NSNumber)?.intValue, pages > 0 else { return finish(nil) }
            webView.setFrameSize(NSSize(width: ReportPDF.pageSize.width, height: ReportPDF.pageSize.height * CGFloat(pages)))
            renderPage(0, of: pages, into: PDFDocument())
        }
    }

    /// Renders pages one at a time, in order, then hands back the joined document.
    private func renderPage(_ index: Int, of pages: Int, into output: PDFDocument) {
        guard index < pages else {
            output.documentAttributes = [
                PDFDocumentAttribute.titleAttribute: "MacSense report: \(report["computer"] as? String ?? "Mac")",
                PDFDocumentAttribute.creatorAttribute: "MacSense",
            ]
            return finish(output.pageCount == pages ? output.dataRepresentation() : nil)
        }
        let size = ReportPDF.pageSize
        let configuration = WKPDFConfiguration()
        configuration.rect = CGRect(x: 0, y: size.height * CGFloat(index), width: size.width, height: size.height)
        webView.createPDF(configuration: configuration) { [self] result in
            guard case .success(let data) = result, let single = PDFDocument(data: data), let page = single.page(at: 0) else {
                return finish(nil)
            }
            output.insert(page, at: output.pageCount)
            renderPage(index + 1, of: pages, into: output)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(nil) }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(nil) }
}

/// Where reports go and what they're called.
enum ReportFiles {
    /// "MacSense report – iMac20,1 – C02XXXXX – 2026-09-23"
    static func baseName(_ report: [String: Any]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let model = (report["model"] as? String ?? "Mac").replacingOccurrences(of: "/", with: "-")
        let serial = report["serial"] as? String ?? ""
        return ["MacSense report", model, serial, formatter.string(from: Date())].filter { !$0.isEmpty }.joined(separator: " – ")
    }

    /// Run from a USB drive, reports default to a "MacSense Reports" folder on that drive; otherwise the Desktop.
    static func defaultFolder() -> URL {
        let bundle = Bundle.main.bundleURL
        if let values = try? bundle.resourceValues(forKeys: [.volumeIsInternalKey, .volumeURLKey]),
           values.volumeIsInternal == false, let volume = values.volume {
            let folder = volume.appendingPathComponent("MacSense Reports", isDirectory: true)
            if (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil { return folder }
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// IT can pre-set the address (and the management system's name) with a Jamf configuration profile
    /// for com.brokengearindustries.macsense: keys ITReportEmail and ManagementName.
    static var itEmail: String? {
        UserDefaults.standard.string(forKey: "ITReportEmail").flatMap { $0.contains("@") ? $0 : nil }
    }

    static func json(_ report: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    }
}

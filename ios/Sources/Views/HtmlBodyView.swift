import SwiftUI
import WebKit

struct HtmlBodyView: UIViewRepresentable {
    let htmlContent: String

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let wrappedHtml = """
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        body { font: -apple-system-body; font-family: -apple-system; margin: 0; padding: 4px; color: CanvasText; }
        :root { color-scheme: light dark; }
        </style>
        \(htmlContent)
        """
        webView.loadHTMLString(wrappedHtml, baseURL: nil)
    }
}

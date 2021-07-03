//
//  Readability.swift
//  SwiftReadability
//
//  Created by Chloe on 2016-06-20.
//  Copyright © 2016 Chloe Horgan. All rights reserved.
//

import Foundation
import WebKit

public enum ReadabilityError: Error {
    case unableToParseScriptResult(rawResult: String?)
    case decodingFailure
    case loadingFailure
}

public enum ReadabilityConversionTime {
    case atDocumentEnd
    case atNavigationFinished
}

public enum ReadabilitySubresourceSuppressionType {
    case none
    case all
    case allExceptScripts
}

public class Readability: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private let webView: WKWebView
    private let completionHandler: ((_ content: String?, _ error: Error?) -> Void)
    private var isRenderingReadabilityHTML = false
    private let conversionTime: ReadabilityConversionTime
    private let suppressSubresourceLoadingDuringConversion: ReadabilitySubresourceSuppressionType
    private var allowNavigationFailures = 0
    private let meaningfulContentMinLength: Int
    
    private let sentryDsn: String?
    private let sentryTracesSampleRate: Double
    
    private let overriddenTemplate: String?
    
    fileprivate var progressCallback: ((_ estimatedProgress: Double) -> Void)?
    fileprivate var downloadBuffer = Data()
    fileprivate var expectedContentLength = 0
    fileprivate var htmlDownloadCompletionHandler: ((String?, Error?) -> Void)?
    
    public init(conversionTime: ReadabilityConversionTime = .atDocumentEnd, suppressSubresourceLoadingDuringConversion: ReadabilitySubresourceSuppressionType = .none, meaningfulContentMinLength: Int? = nil, sentryDsn: String? = nil, sentryTracesSampleRate: Double = 0.05, template: String? = nil, completionHandler: @escaping (_ content: String?, _ error: Error?) -> Void, progressCallback: ((_ estimatedProgress: Double) -> Void)? = nil, contentRulesAddedCallback: ((WKWebView) -> Void)? = nil) {
        let webView = WKWebView(frame: CGRect.zero, configuration: WKWebViewConfiguration())
        
        func completionHandlerWrapper(_ content: String?, _ error: Error?) {
            // See: https://stackoverflow.com/a/32443423/89373
            webView.stopLoading()
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "readabilityJavascriptLoaded")
            webView.navigationDelegate = nil
            completionHandler(content, error)
        }
        
        self.progressCallback = progressCallback
        self.completionHandler = completionHandlerWrapper
        self.conversionTime = conversionTime
        self.suppressSubresourceLoadingDuringConversion = suppressSubresourceLoadingDuringConversion
        self.meaningfulContentMinLength = meaningfulContentMinLength ?? 250
        self.sentryDsn = sentryDsn
        self.sentryTracesSampleRate = sentryTracesSampleRate
        self.overriddenTemplate = template
        self.webView = webView
        
        super.init()
        
        addContentRules(completion: contentRulesAddedCallback)
        
        webView.configuration.suppressesIncrementalRendering = true
        webView.navigationDelegate = self
        webView.configuration.userContentController.add(self, name: "readabilityJavascriptLoaded")
        webView.addObserver(self, forKeyPath: #keyPath(WKWebView.estimatedProgress), options: .new, context: nil)
        
        setJavascript(enabled: false)
        addReadabilityUserScript()
    }
    
    public convenience init(url: URL, conversionTime: ReadabilityConversionTime = .atDocumentEnd, suppressSubresourceLoadingDuringConversion: ReadabilitySubresourceSuppressionType = .none, meaningfulContentMinLength: Int? = nil, sentryDsn: String? = nil, sentryTracesSampleRate: Double = 0.05, template: String? = nil, completionHandler: @escaping (_ content: String?, _ error: Error?) -> Void, progressCallback: ((_ estimatedProgress: Double) -> Void)? = nil) {
        
        self.init(
            conversionTime: conversionTime,
            suppressSubresourceLoadingDuringConversion: suppressSubresourceLoadingDuringConversion,
            meaningfulContentMinLength: meaningfulContentMinLength,
            sentryDsn: sentryDsn,
            sentryTracesSampleRate: sentryTracesSampleRate,
            template: template,
            completionHandler: completionHandler,
            progressCallback: progressCallback,
            contentRulesAddedCallback: { webView in
                webView.load(URLRequest(url: url))
            })
    }
    
    public convenience init(html: String, baseUrl: URL? = nil, conversionTime: ReadabilityConversionTime = .atDocumentEnd, suppressSubresourceLoadingDuringConversion: ReadabilitySubresourceSuppressionType = .none, meaningfulContentMinLength: Int? = nil, sentryDsn: String? = nil, sentryTracesSampleRate: Double = 0.05, template: String? = nil, completionHandler: @escaping (_ content: String?, _ error: Error?) -> Void) {
        
        self.init(
            conversionTime: conversionTime,
            suppressSubresourceLoadingDuringConversion: suppressSubresourceLoadingDuringConversion,
            meaningfulContentMinLength: meaningfulContentMinLength,
            sentryDsn: sentryDsn,
            sentryTracesSampleRate: sentryTracesSampleRate,
            template: template,
            completionHandler: completionHandler,
            contentRulesAddedCallback: { webView in
                webView.loadHTMLString(html, baseURL: baseUrl)
            })
    }
    
    deinit {
        webView.removeObserver(self, forKeyPath: #keyPath(WKWebView.estimatedProgress))
    }
    
    private func setJavascript(enabled: Bool) {
        let preferences = WKPreferences()
        preferences.javaScriptEnabled = enabled
        webView.configuration.preferences = preferences
    }
    
    private func addReadabilityUserScript() {
        let script = ReadabilityUserScript(scriptInjectionTime: .atDocumentEnd)
        webView.configuration.userContentController.addUserScript(script)
    }
    
    private func addContentRules(completion: ((WKWebView) -> Void)? = nil) {
        if suppressSubresourceLoadingDuringConversion == .none {
            return
        }
        
        // We would like to include images here, but they're loaded for readability_images.js sizing calculations.
        var resourceTypesToBlock = ["image", "media", "svg-document", "popup", "style-sheet", "font"]
        if suppressSubresourceLoadingDuringConversion == .all {
            resourceTypesToBlock.append("script")
        }
        
        let blockRules = """
         [{
             "trigger": {
                 "url-filter": ".*",
                 "resource-type": [\(resourceTypesToBlock.map { "\"\($0)\"" } .joined(separator: ", "))]
             },
             "action": {
                 "type": "block"
             }
         }]
        """
        
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "ContentBlockingRules",
            encodedContentRuleList: blockRules) { [weak self] (contentRuleList, error) in
                if let error = error {
                    print(error.localizedDescription)
                    return
                }
                
                if let configuration = self?.webView.configuration, let contentRuleList = contentRuleList {
                    configuration.userContentController.add(contentRuleList)
                }
                
                if let completion = completion, let webView = self?.webView {
                    completion(webView)
                }
            }
    }
    
    private func renderHTML(readabilityTitle: String?, readabilityByline: String?, readabilityContent: String) -> String {
        do {
            let template = try overriddenTemplate ?? loadFile(name: "Reader.template", type: "html")
            
            let readabilityImagesJS = try loadFile(name: "readability_images", type: "js")
            var sentryScript = ""
            if let sentryDsn = sentryDsn {
                sentryScript = """
                    <script
                      src="https://browser.sentry-cdn.com/6.8.0/bundle.min.js"
                      integrity="sha384-a1zd+NHj/GIqnlXIHuEKFontqYxBdK9Zwslrvnhr1KfU9tBDzKbM55gQFXlHYDiD"
                      crossorigin="anonymous"
                    ></script>
                    <script>
                        Sentry.init({
                          dsn: "\(sentryDsn)",
                          /*release: "TODO@" + process.env.npm_package_version,*/
                          integrations: [], //new Sentry.Integrations.BrowserTracing()],

                          // We recommend adjusting this value in production, or using tracesSampler
                          // for finer control
                          tracesSampleRate: \(String(describing: sentryTracesSampleRate)),
                        });
                    </script>
                """
            }
            let mozillaCSS = try loadFile(name: "Reader", type: "css")
            let swiftReadabilityCSS = try loadFile(name: "SwiftReadability", type: "css")
            let css = mozillaCSS + swiftReadabilityCSS
            
            let html = template
                .replacingOccurrences(of: "##CSS##", with: css)
                .replacingOccurrences(of: "##TITLE##", with: readabilityTitle ?? "")
                .replacingOccurrences(of: "##BYLINE##", with: readabilityByline ?? "")
                .replacingOccurrences(of: "##CONTENT##", with: readabilityContent)
                .replacingOccurrences(of: "##SCRIPT##", with: readabilityImagesJS)
                .replacingOccurrences(of: "##SENTRY##", with: sentryScript)
            
            return html
        } catch {
            // TODO: Need better error handling
            fatalError("Failed to render Readability HTML")
        }
    }
    
    private func initializeReadability(completionHandler: @escaping (_ html: String?, _ error: Error?) -> Void) {
        var readabilityInitializationJS: String
        do {
            readabilityInitializationJS = try loadFile(name: "readability_initialization.template", type: "js")
        } catch {
            fatalError("Couldn't load readability_initialization.template.js")
        }
        readabilityInitializationJS = readabilityInitializationJS.replacingOccurrences(of: "##CHAR_THRESHOLD##", with: String(meaningfulContentMinLength))
        
        webView.evaluateJavaScript(readabilityInitializationJS) { [weak self] (result, error) in
            let parseError = ReadabilityError.unableToParseScriptResult(rawResult: result as? String)
            
            guard let resultData = (result as? String)?.data(using: .utf8) else {
                self?.completionHandler(nil, error)
                return
            }
            guard let jsonResultOptional = try? JSONSerialization.jsonObject(with: resultData, options: []), let jsonResult = jsonResultOptional as? [String: String?], let contentOptional = jsonResult["content"], let content = contentOptional, let titleOptional = jsonResult["title"], let bylineOptional = jsonResult["byline"] else {
                self?.completionHandler(nil, parseError)
                return
            }
            guard let html = self?.renderHTML(
                readabilityTitle: titleOptional,
                readabilityByline: bylineOptional,
                readabilityContent: content)
            else {
                    self?.completionHandler(nil, parseError)
                    return
            }
            completionHandler(html, nil)
        }
    }
    
    private func rawPageFinishedLoading() {
        isRenderingReadabilityHTML = true
        
        initializeReadability() { [weak self] (html: String?, error: Error?) in
            self?.isRenderingReadabilityHTML = false
            guard let html = html else {
                self?.completionHandler(nil, error)
                return
            }
            self?.completionHandler(html, nil)
        }
    }
    
    override public func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "estimatedProgress" {
            let estimatedProgress = webView.estimatedProgress
            
            if let progressCallback = progressCallback {
                progressCallback(estimatedProgress)
            }
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }
    
    // MARK: WKScriptMessageHandler delegate
    
    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "readabilityJavascriptLoaded" else {
            print("Unexpected script message name \(message.name)")
            return
        }
        
        if isRenderingReadabilityHTML {
            return
        }
        
        if conversionTime == .atDocumentEnd {
            allowNavigationFailures += 1
            webView.stopLoading()
            rawPageFinishedLoading()
        }
    }
    
    //  MARK: WKNavigationDelegate
    
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if !isRenderingReadabilityHTML {
            rawPageFinishedLoading()
        }
    }
    
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if allowNavigationFailures > 0 {
            allowNavigationFailures -= 1
        } else {
            completionHandler(nil, error)
        }
    }
}

extension Readability: URLSessionDataDelegate {
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        expectedContentLength = Int(response.expectedContentLength)
        
        completionHandler(.allow)
    }
}

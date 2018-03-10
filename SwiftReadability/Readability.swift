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
    private var hasRenderedReadabilityHTML = false
    private let conversionTime: ReadabilityConversionTime
    private let suppressSubresourceLoadingDuringConversion: ReadabilitySubresourceSuppressionType
    private var allowNavigationFailures = 0
    private let meaningfulContentMinLength: Int
    
    fileprivate var progressCallback: ((_ estimatedProgress: Double) -> Void)?
    fileprivate var downloadBuffer = Data()
    fileprivate var expectedContentLength = 0
    fileprivate var htmlDownloadCompletionHandler: ((String?, Error?) -> Void)?
    
    public init(conversionTime: ReadabilityConversionTime = .atDocumentEnd, suppressSubresourceLoadingDuringConversion: ReadabilitySubresourceSuppressionType = .none, meaningfulContentMinLength: Int? = nil, completionHandler: @escaping (_ content: String?, _ error: Error?) -> Void, progressCallback: ((_ estimatedProgress: Double) -> Void)? = nil) {
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
        self.webView = webView
        
        super.init()
        
        webView.configuration.suppressesIncrementalRendering = true
        webView.navigationDelegate = self
        webView.configuration.userContentController.add(self, name: "readabilityJavascriptLoaded")
        webView.addObserver(self, forKeyPath: #keyPath(WKWebView.estimatedProgress), options: .new, context: nil)
        
        addContentRules()
        addReadabilityUserScript()
    }
    
    public convenience init(url: URL, conversionTime: ReadabilityConversionTime = .atDocumentEnd, suppressSubresourceLoadingDuringConversion: ReadabilitySubresourceSuppressionType = .none, meaningfulContentMinLength: Int? = nil, completionHandler: @escaping (_ content: String?, _ error: Error?) -> Void, progressCallback: ((_ estimatedProgress: Double) -> Void)? = nil) {
        
        self.init(
            conversionTime: conversionTime,
            suppressSubresourceLoadingDuringConversion: suppressSubresourceLoadingDuringConversion,
            meaningfulContentMinLength: meaningfulContentMinLength,
            completionHandler: completionHandler,
            progressCallback: progressCallback)
        
        webView.load(URLRequest(url: url))
    }
    
    public convenience init(html: String, baseUrl: URL? = nil, conversionTime: ReadabilityConversionTime = .atDocumentEnd, suppressSubresourceLoadingDuringConversion: ReadabilitySubresourceSuppressionType = .none, meaningfulContentMinLength: Int? = nil, completionHandler: @escaping (_ content: String?, _ error: Error?) -> Void) {
        
        self.init(
            conversionTime: conversionTime,
            suppressSubresourceLoadingDuringConversion: suppressSubresourceLoadingDuringConversion,
            meaningfulContentMinLength: meaningfulContentMinLength,
            completionHandler: completionHandler)
        
        DispatchQueue.main.async { [weak self] in
            self?.webView.loadHTMLString(html, baseURL: baseUrl)
        }
    }
    
    deinit {
        webView.removeObserver(self, forKeyPath: #keyPath(WKWebView.estimatedProgress))
    }
    
    private func addReadabilityUserScript() {
        let script = ReadabilityUserScript(scriptInjectionTime: .atDocumentEnd)
        webView.configuration.userContentController.addUserScript(script)
    }
    
    private func addContentRules() {
        if suppressSubresourceLoadingDuringConversion == .none {
            return
        }
        
        // We would like to include images here, but they're loaded for readability_images.js sizing calculations.
        var resourceTypesToBlock = ["images", "media", "svg-document", "popup", "style-sheet", "font"]
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
                if let _ = error {
                    return
                }
                
                if let configuration = self?.webView.configuration, let contentRuleList = contentRuleList {
                    configuration.userContentController.add(contentRuleList)
                }
            }
    }
    
    private func renderHTML(readabilityTitle: String?, readabilityByline: String?, readabilityContent: String) -> String {
        do {
            let template = try loadFile(name: "Reader.template", type: "html")
            
            let readabilityImagesJS = try loadFile(name: "readability_images", type: "js")
            let mozillaCSS = try loadFile(name: "Reader", type: "css")
            let swiftReadabilityCSS = try loadFile(name: "SwiftReadability", type: "css")
            let css = mozillaCSS + swiftReadabilityCSS
            
            let html = template
                .replacingOccurrences(of: "##CSS##", with: css)
                .replacingOccurrences(of: "##TITLE##", with: readabilityTitle ?? "")
                .replacingOccurrences(of: "##BYLINE##", with: readabilityByline ?? "")
                .replacingOccurrences(of: "##CONTENT##", with: readabilityContent)
                .replacingOccurrences(of: "##SCRIPT##", with: readabilityImagesJS)
            
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
        readabilityInitializationJS = readabilityInitializationJS.replacingOccurrences(of: "##MEANINGFUL_CONTENT_MIN_LENGTH##", with: String(meaningfulContentMinLength))
        
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
                readabilityContent: content) else {
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
            self?.hasRenderedReadabilityHTML = true
            guard let html = html else {
                self?.completionHandler(nil, error)
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.webView.configuration.userContentController.removeAllUserScripts()
                self?.webView.loadHTMLString(html, baseURL: self?.webView.url?.baseURL)
            }
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
        
        if isRenderingReadabilityHTML || hasRenderedReadabilityHTML {
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
        if !(isRenderingReadabilityHTML || hasRenderedReadabilityHTML) {
            rawPageFinishedLoading()
        } else if !isRenderingReadabilityHTML {
            webView.evaluateJavaScript("document.documentElement.outerHTML.toString()") { [weak self] (result, error) in
                guard let html = result as? String else {
                    self?.completionHandler(nil, error)
                    return
                }
                self?.completionHandler(html, nil)
            }
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

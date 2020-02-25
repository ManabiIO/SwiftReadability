//
//  ViewController.swift
//  SwiftReadabilityExample
//
//  Created by Alex Ehlke on 2017-06-17.
//  Copyright © 2017 Chloe Horgan. All rights reserved.
//

import SwiftReadability
import UIKit

class ViewController: UIViewController {
    let readabilityViewController = ReadabilityViewController()
    
    //    let articleURL = URL(string: "http://www.cnn.com/2016/06/27/foodanddrink/german-beer-purity-us-beer-gardens/index.html")
    //    let articleURL = URL(string: "https://ca.yahoo.com/?p=us")
    //    let articleURL = URL(string: "http://m.huffpost.com/jp/entry/16733188")//http://www.huffingtonpost.jp/2017/05/20/shogi-master-loses-to-ai_n_16733188.html")
//    let articleURL = URL(string: "http://www.huffingtonpost.jp/techcrunch-japan/amazon-is-gobbling-whole-foods-for-a-reported-13-7-billion_b_17171132.html?utm_hp_ref=japan&ir=Japan")
//    let articleURL = URL(string: "http://natgeo.nikkeibp.co.jp/atcl/news/16/c/061500045/?rss")
//    let articleURL = URL(string: "http://hukumusume.com/douwa/pc/aesop/01/01.htm")
    
//    let articleURL = URL(string: "http://www.hiraganatimes.com/ja/past-articles/food/4345/")
//    let articleURL = URL(string: "https://www.businessinsider.jp/post-34527")
//    let articleURL = URL(string: "http://www.huffingtonpost.jp/2017/07/01/earthquake-kumamoto0702_n_17358712.html?utm_hp_ref=japan&ir=Japan")
//    let articleURL = URL(string: "http://www.ichitetsu.com/2017/08/84-064b.html")
//    let articleURL = URL(string: "https://www.cnn.co.jp/m/usa/35115947.html")
    let articleURL = URL(string: "https://matcha-jp.com/easy/1064")
    //let articleURL = URL(string: "https://github.com/blog/2195-the-shape-of-open-source")
    
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        guard let articleURL = articleURL else { return }
        
        readabilityViewController.willMove(toParent: self)
        addChild(readabilityViewController)
        readabilityViewController.didMove(toParent: self)
        
        view.addSubview(readabilityViewController.view)
        readabilityViewController.view.frame = view.frame
        
        let progressView = UIProgressView(progressViewStyle: .bar)
        view.addSubview(progressView)
        progressView.center = view.center
        
        let completionHandler: (_ content: String?, _ error: Error?) -> Void = { _, _ in
            progressView.isHidden = true
        }
        
        let progressCallback: (_ estimatedProgress: Double) -> Void = { estimatedProgress in
            progressView.progress = Float(estimatedProgress)
        }
        
        readabilityViewController.loadURL(
            url: articleURL,
            completionHandler: completionHandler,
            progressCallback: progressCallback)
        
//        let html = "<p><img class=\"aligncenter size-full wp-image-4353\" src=\"http://www.hiraganatimes.com/wp/wp-content/uploads/2016/06/201508-4.jpg\" alt=\"201508-4\" /></p>\n<p>明治時代（19～20世紀）を中心とした貴重な建造物を集めた野外博物館。今年オープンから50年を迎えた。著名なアメリカ人建築家、フランク・ロイド・ライトが建てた旧帝国ホテルでは軽食が楽しめる。蒸気機関車やレトロな京都市電、バスが毎日運転を行い、広大な敷地内の移動に利用できる。着物や袴姿での記念撮影体験や、季節ごとのイベントも数多く開催。映像作品のロケに使われることも多い。</p>\n<ul>\n<li>交通：名鉄犬山線犬山駅から路線バス明治村行き20分、下車すぐ。</li>\n<li>営業時間：午前9時30分～午後5時（季節によって時間帯の変更あり）</li>\n<li>休村日：8月4日、18日、25日、12月31日、12～2月の毎週月曜日。1月に数日間メンテナンス休日あり。</li>\n<li>入村料：大人（18歳以上）1,700円、乗り物一日券付きは2,700円</li>\n</ul>\n<p><a href=\"http://www.meijimura.com\" target=\"_blank\">博物館 明治村</a></p>\n"
//        loadHTML(html: html, withBaseURL: articleURL)
    }
}

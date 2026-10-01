import Foundation
import WebKit

enum WebLoginDataCleaner {
    static func clearNetEase() {
        clear(domains: ["music.163.com", "163.com"])
    }

    static func clearQQMusic() {
        clear(domains: ["y.qq.com", "qq.com", "ptlogin2.qq.com"])
    }

    static func clearKugou() {
        clear(domains: ["kugou.com", "login-user.kugou.com", "h5.kugou.com"])
    }

    private static func clear(domains: [String]) {
        let store = WKWebsiteDataStore.default()
        store.httpCookieStore.getAllCookies { cookies in
            for cookie in cookies where domains.contains(where: { cookie.domain.contains($0) }) {
                store.httpCookieStore.delete(cookie)
            }
        }
        WKWebsiteDataStore.default().fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            let matched = records.filter { record in
                domains.contains { domain in
                    record.displayName.contains(domain) || domain.contains(record.displayName)
                }
            }
            WKWebsiteDataStore.default().removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                for: matched,
                completionHandler: {}
            )
        }
    }
}

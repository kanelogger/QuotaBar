import Foundation
import QuotaCore
import SweetCookieKit

struct KimiBrowserCookieImporter {
    func resolveToken() throws -> String {
        let client = BrowserCookieClient()
        let query = BrowserCookieQuery(
            domains: ["www.kimi.com", "kimi.com"],
            domainMatch: .suffix,
            includeExpired: false
        )

        for browser in Browser.defaultImportOrder {
            guard let stores = try? client.records(matching: query, in: browser) else { continue }
            for store in stores {
                let cookies = store.cookies(origin: query.origin)
                if let cookie = cookies.first(where: { $0.name == "kimi-auth" }), !cookie.value.isEmpty {
                    return cookie.value
                }
            }
        }
        throw QuotaError.permissionDenied("未找到 kimi-auth；请先登录 Kimi，并为 QuotaBar 开启完全磁盘访问权限")
    }
}

struct KimiCredentialProvider: CredentialProviding, @unchecked Sendable {
    let keychain: any CredentialProviding
    let browserToken: @Sendable () throws -> String

    init(
        keychain: any CredentialProviding,
        browserToken: @escaping @Sendable () throws -> String = {
            try KimiBrowserCookieImporter().resolveToken()
        }
    ) {
        self.keychain = keychain
        self.browserToken = browserToken
    }

    func credential(for providerID: ProviderID) throws -> String? {
        if let manualToken = try keychain.credential(for: .kimi), !manualToken.isEmpty {
            return manualToken
        }
        return try browserToken()
    }
}

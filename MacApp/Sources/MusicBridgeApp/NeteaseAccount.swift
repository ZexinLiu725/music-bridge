import AppKit
import CoreImage
import Foundation

/// NetEase account sign-in by QR code, plus the profile read that tells
/// the app what the account is entitled to. The session cookie lives only
/// in this app's preferences on this Mac — never in the project folder,
/// a repository, or an installer — the same rule as the Apple wrapper's
/// data.img.
///
/// Transport is the clients' own "eapi" envelope (see EapiCrypto): the
/// QR endpoints are called on interfacepc.music.163.com with an
/// encrypted payload that carries a desktop-client fingerprint header
/// (deviceId / os / appver / channel / requestId). Plain unsigned calls
/// — even to the current type=3 endpoints — are answered 801/802 and
/// then refused after the phone confirms (code 8821, NetEase risk
/// control asking for a newer client); the fingerprint is what the
/// risk system is checking. The deviceId is generated once and kept in
/// preferences so this Mac presents as one stable client, the same way
/// a real install would. It is a device fingerprint, not a credential.
///
/// Replies are read without any cookie jar: the session cookie is
/// captured from the confirming response's own Set-Cookie headers (or
/// a cookie string echoed in the body), never from shared storage.
enum NeteaseLoginPoll {
    case waiting
    case scanned
    /// The phone confirmed (code 803) but no session cookie came back
    /// with the response; keep polling briefly, it can trail the code.
    case confirmed
    case expired
    /// NetEase risk control answered instead of a login state (8821 and
    /// friends): this key will never complete, stop and say so.
    case blocked(message: String)
    case success(cookieHeader: String)
}

struct NeteaseProfile {
    let nickname: String
    let vipType: Int
    var isVIP: Bool { vipType > 0 }
}

enum NeteaseAccountError: LocalizedError {
    case qrUnavailable
    case profileUnavailable

    var errorDescription: String? {
        switch self {
        case .qrUnavailable: return "网易云没有返回登录二维码，请稍后重试。"
        case .profileUnavailable: return "网易云账号信息读取失败。"
        }
    }
}

struct NeteaseAccountClient {
    /// The UA the reference client stack pairs with the pc fingerprint
    /// header below. The mismatch is theirs, it is what their requests
    /// actually send, and it passes — do not "fix" it into coherence.
    private static let clientUserAgent = "NeteaseMusic 9.0.90/5038 (iPhone; iOS 16.2; zh_CN)"
    private static let webUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15"

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        session = URLSession(configuration: configuration)
    }

    func createLoginQR() async throws -> (key: String, image: NSImage) {
        let (data, _) = try await eapiPost(path: "/api/login/qrcode/unikey",
                                           business: ["type": 3])
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = (root["unikey"] as? String) ?? ((root["data"] as? [String: Any])?["unikey"] as? String),
              !key.isEmpty,
              let image = Self.qrImage(for: "https://music.163.com/login?codekey=\(key)") else {
            throw NeteaseAccountError.qrUnavailable
        }
        return (key, image)
    }

    /// One status poll. Never throws: transport and parse failures come
    /// back as .waiting plus a debug line describing what actually
    /// arrived, so a malformed success response can no longer
    /// masquerade as "still waiting" the way a swallowed throw did.
    func pollLogin(key: String) async -> (result: NeteaseLoginPoll, debug: String) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await eapiPost(path: "/api/login/qrcode/client/login",
                                                  business: ["key": key, "type": 3])
        } catch {
            return (.waiting, "轮询请求失败：\(error.localizedDescription)")
        }
        // The session cookie, when the phone has confirmed, rides this
        // response's own Set-Cookie headers; read them through the API
        // built for coalesced header values.
        var responseCookieHeader: String? = nil
        if let http = response as? HTTPURLResponse,
           let fields = http.allHeaderFields as? [String: String],
           let url = response.url {
            let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
            if cookies.contains(where: { $0.name == "MUSIC_U" && !$0.value.isEmpty }) {
                responseCookieHeader = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            }
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            let snippet = String(data: Data(data.prefix(160)), encoding: .utf8) ?? "<非文本响应 \(data.count) 字节>"
            if let responseCookieHeader {
                return (.success(cookieHeader: responseCookieHeader), "轮询：响应头 Set-Cookie 拿到 MUSIC_U（正文非 JSON）")
            }
            return (.waiting, "轮询：响应不是 JSON，原文：\(snippet)")
        }
        // The payload can sit at the top level or nested under "data";
        // accept both.
        let payload = (root["data"] as? [String: Any]) ?? root
        let code: Int?
        if let number = payload["code"] as? NSNumber { code = number.intValue }
        else if let text = payload["code"] as? String { code = Int(text) }
        else if let number = root["code"] as? NSNumber { code = number.intValue }
        else { code = nil }
        let message = (payload["message"] as? String) ?? (root["message"] as? String) ?? ""
        let bodyCookie = ((payload["cookie"] as? String) ?? (root["cookie"] as? String))
            .flatMap { Self.cookieHeader(from: $0) }
        var debug = "轮询：code=\(code.map(String.init) ?? "无")，响应头\(responseCookieHeader != nil ? "有" : "无") MUSIC_U，正文 cookie\(bodyCookie != nil ? "有" : "无")"
        if !message.isEmpty { debug += "，message=\(message)" }
        if let responseCookieHeader {
            return (.success(cookieHeader: responseCookieHeader), debug)
        }
        guard let code else { return (.waiting, debug) }
        switch code {
        case 801: return (.waiting, debug)
        case 802: return (.scanned, debug)
        case 800: return (.expired, debug)
        case 803:
            // Some deployments also echo the session as a cookie string
            // in the body; accept it if it carries MUSIC_U.
            if let bodyCookie { return (.success(cookieHeader: bodyCookie), debug) }
            return (.confirmed, debug)
        case 8821, 8810, -462:
            return (.blocked(message: message.isEmpty ? "网易云要求切换登录方式或完成验证（code \(code)）" : message), debug)
        default: return (.waiting, debug)
        }
    }

    func fetchProfile(cookieHeader: String) async throws -> NeteaseProfile {
        let data = try await get(URL(string: "https://music.163.com/api/nuser/account/get")!,
                                 cookieHeader: cookieHeader)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let nickname = profile["nickname"] as? String, !nickname.isEmpty else {
            throw NeteaseAccountError.profileUnavailable
        }
        let vip = (profile["vipType"] as? NSNumber)?.intValue
            ?? ((root["account"] as? [String: Any])?["vipType"] as? NSNumber)?.intValue ?? 0
        return NeteaseProfile(nickname: nickname, vipType: vip)
    }

    // MARK: - eapi transport

    /// One encrypted eapi call. `path` is the plain API path
    /// ("/api/login/qrcode/unikey"); the wire URL is the eapi host with
    /// "/eapi/" substituted, and the payload gains the client header
    /// object and e_r=false (plain JSON replies) before encryption.
    private func eapiPost(path: String, business: [String: Any]) async throws -> (Data, URLResponse) {
        // One header object per request, used for both the encrypted
        // payload and the Cookie header, exactly as the client stack
        // does — the two must agree, requestId included.
        let fields = Self.clientHeaderFields()
        var payload = business
        payload["e_r"] = false
        payload["header"] = Self.clientHeaderObject(fields: fields)
        let jsonData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let jsonText = String(decoding: jsonData, as: UTF8.self)
        let params = EapiCrypto.params(path: path, jsonText: jsonText)

        let eapiPath = "/eapi/" + path.dropFirst("/api/".count)
        var request = URLRequest(url: URL(string: "https://interfacepc.music.163.com\(eapiPath)")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.clientUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.clientCookieHeader(fields: fields), forHTTPHeaderField: "Cookie")
        request.httpBody = Data("params=\(params)".utf8)
        request.timeoutInterval = 20
        return try await session.data(for: request)
    }

    /// The desktop-client fingerprint, in the field order the client
    /// stack emits it. buildver and requestId are per-request; the rest
    /// is one stable identity for this Mac.
    private static func clientHeaderFields() -> [(String, String)] {
        let now = Date()
        let requestId = "\(Int(now.timeIntervalSince1970 * 1000))_\(String(format: "%04d", Int.random(in: 0..<1000)))"
        return [
            ("osver", "Microsoft-Windows-10-Professional-build-19045-64bit"),
            ("deviceId", deviceId()),
            ("os", "pc"),
            ("appver", "3.1.17.204416"),
            ("versioncode", "140"),
            ("mobilename", ""),
            ("buildver", String(Int(now.timeIntervalSince1970))),
            ("resolution", "1920x1080"),
            ("__csrf", ""),
            ("channel", "netease"),
            ("requestId", requestId),
        ]
    }

    private static func clientHeaderObject(fields: [(String, String)]) -> [String: Any] {
        var object: [String: Any] = [:]
        for (name, value) in fields { object[name] = value }
        return object
    }

    /// The same fields as a Cookie header, escaped the way the client
    /// stack's encodeURIComponent-based joiner escapes them.
    private static func clientCookieHeader(fields: [(String, String)]) -> String {
        fields
            .map { "\(uriComponentEscape($0.0))=\(uriComponentEscape($0.1))" }
            .joined(separator: "; ")
    }

    private static func uriComponentEscape(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        var out = ""
        for byte in value.utf8 {
            if allowed.contains(UnicodeScalar(byte)) {
                out.append(Character(UnicodeScalar(byte)))
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    /// One stable 52-hex device identity for this Mac, generated on
    /// first use and kept in preferences (a fingerprint, not a secret).
    private static func deviceId() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: "neteaseDeviceId"), existing.count == 52 {
            return existing
        }
        let hex = "0123456789ABCDEF"
        let generated = String((0..<52).map { _ in hex.randomElement()! })
        defaults.set(generated, forKey: "neteaseDeviceId")
        return generated
    }

    /// Parse a "name=value; name2=value2" cookie string into a header,
    /// returning nil unless it carries a usable MUSIC_U.
    private static func cookieHeader(from text: String) -> String? {
        var pairs: [String: String] = [:]
        let attributes: Set<String> = ["expires", "path", "domain", "max-age", "samesite", "secure", "httponly"]
        for part in text.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let name = String(kv[0]).trimmingCharacters(in: .whitespaces)
            guard !attributes.contains(name.lowercased()) else { continue }
            pairs[name] = String(kv[1]).trimmingCharacters(in: .whitespaces)
        }
        guard let musicU = pairs["MUSIC_U"], !musicU.isEmpty else { return nil }
        return pairs.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    private func get(_ url: URL, cookieHeader: String?) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        request.setValue(Self.webUserAgent, forHTTPHeaderField: "User-Agent")
        if let cookieHeader, !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        request.timeoutInterval = 20
        let (data, _) = try await session.data(for: request)
        return data
    }

    private static func qrImage(for text: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

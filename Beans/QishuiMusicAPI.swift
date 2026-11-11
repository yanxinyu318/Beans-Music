import Foundation

/// 汽水音乐（Soda Music / Luna）最小版接入。
///
/// 只用今晚（2026-11-11）实测通过的四条路，不用已死的接口：
/// - 第三方中转 api.vsaa.cn 已 404，**不要用**；
/// - 官方 PC 歌曲搜索 /luna/pc/search/track 回空 / ERR_INVALID_PARAM，
///   **没有歌曲搜索**，搜索页只能搜歌单；
/// - App 播放接口 POST /luna/media-player 被上游拒“应用版本有风险”，**不要用**。
///
/// 实测通过的路（请求格式照抄 guowenye/qishui-api 的 src/qishuiClient.js）：
/// 1. 推荐歌单：POST https://beta-luna.douyin.com/luna/discover/mix
/// 2. 歌单搜索：GET https://api.qishui.com/luna/pc/search/mixed（只取 playlists，tracks 恒为空）
/// 3. 歌单详情：POST https://beta-luna.douyin.com/luna/playlist/detail
/// 4. 单曲音频+歌词：GET https://beta-luna.douyin.com/luna/h5/seo_track
///
/// 音频是整首但只有约 64kbps，链接带签名会过期：播放时现取现用，不缓存 URL，
/// 不声称高音质。歌词有的歌是空串，调用方按“暂无歌词”空态处理。
final class QishuiMusicAPI {
    static let shared = QishuiMusicAPI()

    private let lunaHost = "https://beta-luna.douyin.com"
    private let pcHost = "https://api.qishui.com"
    private let appUA = "Luna/19.1.0 Android"
    private let pcUA = "LunaPC/3.0.0(290101097)"
    private let webUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36"

    private let session: URLSession
    /// 随机设备标识（只在进程内生成一次，不含任何账号信息）。
    private let deviceId: String
    private let installId: String

    /// 单曲音频+歌词的小缓存：避免播放器取地址和歌词页各请求一次。
    /// 只存 10 分钟，签名链接过期前失效，不持久化。
    private struct AudioCacheEntry {
        let audioURL: String?
        let lyric: String
        let fetchedAt: Date
    }
    private var audioCache: [String: AudioCacheEntry] = [:]
    private let audioCacheQueue = DispatchQueue(label: "beans.qishui.audioCache")

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config)
        deviceId = Self.randomNumeric(length: 16)
        installId = Self.randomNumeric(length: 16)
    }

    // MARK: - 对外接口（失败返回空结果，不抛错、不崩溃）

    /// 推荐歌单（发现页唯一栏目）。
    func recommendPlaylists(limit: Int = 12) async -> [Playlist] {
        let body: [String: Any] = ["count": max(1, min(limit, 30))]
        guard let json = try? await postJSON(
            url: lunaHost + "/luna/discover/mix",
            body: body,
            userAgent: appUA
        ) else {
            BeansLogger.shared.log("汽水音乐推荐歌单请求失败", level: .warn)
            return []
        }
        let blocks = json["inner_block"] as? [[String: Any]] ?? []
        let playlists: [Playlist] = blocks
            .flatMap { ($0["resources"] as? [[String: Any]]) ?? [] }
            .compactMap { resource in
                guard let entity = resource["entity"] as? [String: Any],
                      let raw = entity["playlist"] as? [String: Any] else { return nil }
                return Self.playlist(from: raw)
            }
        return Array(playlists.prefix(limit))
    }

    /// 歌单搜索。注意：这是**歌单**搜索，不是歌曲搜索——
    /// 上游混合搜索返回的 tracks 恒为空，不要指望它搜到单曲。
    func searchPlaylists(keyword: String, limit: Int = 20) async -> [Playlist] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let items: [URLQueryItem] = [
            URLQueryItem(name: "aid", value: "386088"),
            URLQueryItem(name: "app_name", value: "luna_pc"),
            URLQueryItem(name: "region", value: "cn"),
            URLQueryItem(name: "geo_region", value: "cn"),
            URLQueryItem(name: "os_region", value: "cn"),
            URLQueryItem(name: "device_id", value: deviceId),
            URLQueryItem(name: "iid", value: installId),
            URLQueryItem(name: "version_name", value: "3.0.0"),
            URLQueryItem(name: "version_code", value: "30000000"),
            URLQueryItem(name: "channel", value: "official"),
            URLQueryItem(name: "device_platform", value: "windows"),
            URLQueryItem(name: "device_type", value: "Windows"),
            URLQueryItem(name: "os_version", value: "Windows 11"),
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "cursor", value: "0"),
            URLQueryItem(name: "search_method", value: "input"),
        ]
        var components = URLComponents(string: pcHost + "/luna/pc/search/mixed")
        components?.queryItems = items
        guard let url = components?.url,
              let json = try? await getJSON(url: url, userAgent: pcUA) else { return [] }
        let groups = json["result_groups"] as? [[String: Any]] ?? []
        let playlists: [Playlist] = groups
            .flatMap { ($0["data"] as? [[String: Any]]) ?? [] }
            .compactMap { resource -> Playlist? in
                let entity = (resource["entity"] as? [String: Any]) ?? resource
                guard let raw = entity["playlist"] as? [String: Any] else { return nil }
                return Self.playlist(from: raw)
            }
        return Array(playlists.prefix(limit))
    }

    /// 歌单详情：返回歌单内的全部曲目（上限 20 首起，按需可再翻页，本版不做翻页）。
    func playlistDetail(playlistId: String, count: Int = 20) async -> [Song] {
        let body: [String: Any] = [
            "playlist_id": playlistId,
            "count": max(1, min(count, 50)),
        ]
        guard let json = try? await postJSON(
            url: lunaHost + "/luna/playlist/detail",
            body: body,
            userAgent: appUA
        ) else { return [] }
        let resources = json["media_resources"] as? [[String: Any]] ?? []
        return resources.compactMap { resource in
            let entity = (resource["entity"] as? [String: Any]) ?? resource
            let track = (entity["track_wrapper"] as? [String: Any])?["track"] as? [String: Any]
                ?? entity["track"] as? [String: Any]
                ?? resource["track"] as? [String: Any]
            guard let track else { return nil }
            return Self.song(from: track)
        }
    }

    /// 单曲音频地址 + 歌词（现取现用）。
    /// audioURL 为空表示这首歌暂时拿不到可播地址；lyric 为空串表示上游没有歌词。
    func songAudioAndLyric(trackId: String) async -> (audioURL: String?, lyric: String) {
        if let cached = cachedAudio(for: trackId) {
            return (cached.audioURL, cached.lyric)
        }
        var components = URLComponents(string: lunaHost + "/luna/h5/seo_track")
        components?.queryItems = [
            URLQueryItem(name: "track_id", value: trackId),
            URLQueryItem(name: "device_platform", value: "web"),
        ]
        guard let url = components?.url,
              let json = try? await getJSON(url: url, userAgent: webUA) else {
            return (nil, "")
        }
        // 歌词：lyric.content，汽水原格式是 [毫秒,时长]<逐字时间>歌词，
        // 转成标准 LRC（[mm:ss.cc]歌词）再交给 LyricParser。
        let rawLyric = (json["lyric"] as? [String: Any])?["content"] as? String ?? ""
        let lyric = Self.normalizeLyric(rawLyric)
        var audioURL: String?
        if let trackPlayer = json["track_player"] as? [String: Any],
           let videoModelString = trackPlayer["video_model"] as? String,
           let videoModelData = videoModelString.data(using: .utf8),
           let videoModel = try? JSONSerialization.jsonObject(with: videoModelData) as? [String: Any],
           let videoList = videoModel["video_list"] as? [[String: Any]],
           let first = videoList.first {
            let main = Self.string(first["main_url"])
            let backup = Self.string(first["backup_url"])
            audioURL = !main.isEmpty ? main : (!backup.isEmpty ? backup : nil)
        }
        if audioURL == nil {
            BeansLogger.shared.log("汽水音乐未拿到播放地址 trackId=\(trackId)", level: .warn)
        }
        cacheAudio(trackId: trackId, audioURL: audioURL, lyric: lyric)
        return (audioURL, lyric)
    }

    // MARK: - 歌词格式转换

    /// 把汽水逐字歌词 `[60,1470]<0,350,0>不<400,340,0>敢…` 转成标准 LRC。
    /// 已是 `[mm:ss.xx]` 的行原样保留；空串原样返回空串。
    static func normalizeLyric(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        var lines: [String] = []
        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let converted = convertWordTimedLine(trimmed) {
                lines.append(converted)
            } else if trimmed.hasPrefix("[") {
                // 已是标准时间戳格式或 [offset:] 等元信息行，原样保留
                lines.append(trimmed)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// `[60,1470]<0,350,0>不<400,340,0>敢<740,330,0>回看` -> `[00:00.06]不敢回看`
    private static func convertWordTimedLine(_ line: String) -> String? {
        // 行首 [startMs,durationMs]
        guard line.hasPrefix("["),
              let close = line.firstIndex(of: "]") else { return nil }
        let head = String(line[line.index(after: line.startIndex)..<close])
        let parts = head.split(separator: ",")
        guard parts.count >= 1, let startMs = Double(parts[0]) else { return nil }
        let body = String(line[line.index(after: close)...])
        // 逐字时间 <start,duration,flag> 全部去掉，只留歌词字
        let text = body
            .replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        let totalSeconds = startMs / 1000.0
        let minutes = Int(totalSeconds / 60)
        let seconds = totalSeconds - Double(minutes * 60)
        return String(format: "[%02d:%05.2f]%@", minutes, seconds, text)
    }

    // MARK: - 模型转换

    /// 汽水歌单 id 是 19 位数字字符串，Playlist.id 是 Int：取后 15 位转 Int，
    /// 完整 id 另存 qishuiId，查详情时以 qishuiId 为准。
    static func playlist(from raw: [String: Any]) -> Playlist? {
        let fullId = string(raw["id"])
        guard !fullId.isEmpty else { return nil }
        let name = string(raw["title"]).isEmpty ? string(raw["name"]) : string(raw["title"])
        guard !name.isEmpty else { return nil }
        let count = intValue(raw["count_tracks"] ?? raw["track_count"] ?? raw["song_count"])
        return Playlist(
            id: truncatedID(fullId),
            name: name,
            coverURL: coverURL(from: raw["url_cover"] ?? raw["cover"] ?? raw["cover_url"]),
            trackCount: count,
            source: .qishui,
            qishuiId: fullId
        )
    }

    static func song(from track: [String: Any]) -> Song? {
        let fullId = string(track["id"])
        guard !fullId.isEmpty else { return nil }
        let name = string(track["name"])
        guard !name.isEmpty else { return nil }
        let album = track["album"] as? [String: Any] ?? [:]
        let artists = (track["artists"] as? [[String: Any]] ?? [])
            .map { string($0["name"]).isEmpty ? string(($0["user_info"] as? [String: Any])?["nickname"]) : string($0["name"]) }
            .filter { !$0.isEmpty }
            .joined(separator: " / ")
        let durationMs = doubleValue(track["duration"] ?? track["duration_ms"])
        return Song(
            id: truncatedID(fullId),
            name: name,
            artists: artists,
            album: string(album["name"]),
            coverURL: coverURL(from: album["url_cover"] ?? album["cover_url"] ?? album["coverURL"]),
            duration: durationMs / 1000.0,
            source: .qishui,
            qishuiTrackId: fullId
        )
    }

    /// 19 位数字 id 取后 15 位转 Int（15 位 < Int64 上限，不会溢出；
    /// 仅用于 Song/Playlist 的 Int id 槽位，真正请求一律用完整字符串）。
    static func truncatedID(_ fullId: String) -> Int {
        let digits = fullId.filter { $0.isNumber }
        let tail = String(digits.suffix(15))
        return Int(tail) ?? 0
    }

    /// 封面字段可能是 {urls:[…], uri:"…"}，也可能是纯字符串。
    static func coverURL(from value: Any?) -> URL? {
        switch value {
        case let dict as [String: Any]:
            if let urls = dict["urls"] as? [String], let first = urls.first, !first.isEmpty,
               let uri = dict["uri"] as? String {
                return URL(string: first + uri)
            }
            if let url = dict["url"] as? String, !url.isEmpty { return URL(string: url) }
            if let uri = dict["uri"] as? String, uri.hasPrefix("http") { return URL(string: uri) }
            return nil
        case let text as String:
            return text.isEmpty ? nil : URL(string: text)
        default:
            return nil
        }
    }

    // MARK: - 网络

    private func getJSON(url: URL, userAgent: String) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NetEaseError.network
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NetEaseError.decoding("汽水接口返回不是 JSON")
        }
        return json
    }

    private func postJSON(url: String, body: [String: Any], userAgent: String) async throws -> [String: Any] {
        guard let url = URL(string: url) else { throw NetEaseError.unknown("汽水请求地址无效") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NetEaseError.network
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NetEaseError.decoding("汽水接口返回不是 JSON")
        }
        return json
    }

    // MARK: - 小工具

    private func cachedAudio(for trackId: String) -> AudioCacheEntry? {
        audioCacheQueue.sync {
            guard let entry = audioCache[trackId],
                  Date().timeIntervalSince(entry.fetchedAt) < 600 else { return nil }
            return entry
        }
    }

    private func cacheAudio(trackId: String, audioURL: String?, lyric: String) {
        audioCacheQueue.sync {
            audioCache[trackId] = AudioCacheEntry(audioURL: audioURL, lyric: lyric, fetchedAt: Date())
        }
    }

    private static func randomNumeric(length: Int) -> String {
        var result = ""
        while result.count < length {
            result += String(Int.random(in: 0...9))
        }
        return result
    }

    /// id 可能是数字也可能是字符串，一律转 String。
    static func string(_ value: Any?) -> String {
        switch value {
        case let text as String: return text
        case let number as NSNumber: return number.stringValue
        case let number as Int: return String(number)
        case let number as Int64: return String(number)
        default: return ""
        }
    }

    private static func intValue(_ value: Any?) -> Int {
        switch value {
        case let number as NSNumber: return number.intValue
        case let text as String: return Int(text) ?? 0
        default: return 0
        }
    }

    private static func doubleValue(_ value: Any?) -> Double {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let text as String: return Double(text) ?? 0
        default: return 0
        }
    }
}

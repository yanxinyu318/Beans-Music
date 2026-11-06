import UIKit

/// 复用本地图片解码结果，避免设置页/歌词页滚动时反复从磁盘解码大图。
enum BeansImageFileCache {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(at path: String) -> UIImage? {
        guard !path.isEmpty else { return nil }
        let key = path as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let image = UIImage(contentsOfFile: path) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    static func remove(_ path: String) {
        guard !path.isEmpty else { return }
        cache.removeObject(forKey: path as NSString)
    }

    static func removeAll() {
        cache.removeAllObjects()
    }
}

/// 切歌封面预取：上一首/下一首的封面在当前歌曲播放期间就提前下载进内存，
/// 切歌时 CoverImage 直接取缓存渲染，不用等网络现下。
/// 根因：封面之前全靠 AsyncImage 现下，歌名（本地文本）瞬间就变了，封面却要等几秒才下载完，
/// 看起来就是“标题先变、封面几秒后才跟上”，滑动一点都不丝滑。
/// 未命中缓存时 CoverImage 仍走原来的 AsyncImage，行为不变。
enum BeansCoverPrefetch {
    private static let cache = NSCache<NSURL, UIImage>()
    private static var inflight: Set<URL> = []
    private static let lock = NSLock()

    static func cachedImage(for url: URL?) -> UIImage? {
        guard let url else { return nil }
        return cache.object(forKey: url as NSURL)
    }

    static func prefetch(_ urls: [URL?]) {
        for url in urls {
            guard let url else { continue }
            if cache.object(forKey: url as NSURL) != nil { continue }
            lock.lock()
            let started = inflight.insert(url).inserted
            lock.unlock()
            guard started else { continue }
            URLSession.shared.dataTask(with: url) { data, _, _ in
                lock.lock()
                inflight.remove(url)
                lock.unlock()
                guard let data, let image = UIImage(data: data) else { return }
                cache.setObject(image, forKey: url as NSURL)
            }.resume()
        }
    }
}

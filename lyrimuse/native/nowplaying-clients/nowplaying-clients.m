// 按 bundle id 直接问系统"那个播放器自己在报什么" —— 绕开「系统级 Now Playing 只有一个焦点」。
//
// ## 为什么要有它
//
// MediaRemote 的「正在播放」是系统级单一焦点,浏览器里一个 video 元素就能占走。焦点一被占,
// media-control 那条路读到的就是**占用者**的东西,目标播放器的状态整个读不到 —— 而它多半还在放。
// 但系统其实**同时保留着每个注册过 now playing 的 App 各自的状态**,只是 media-control 只取了
// 当选的那一个。这里取的是全部。
//
// ⚠️ 别跟 `MRMediaRemoteGetActivePlayerPathsForOrigin` 搞混:那个的 "active" 就是"当选的那一个",
// 焦点被占时它只返回占用者,目标播放器的 path 直接从列表里消失。能用的是下面这两个。
//
// ## 两个接口与它们的签名
//
//   MRMediaRemoteGetNowPlayingClients(queue, ^(NSArray<MRClient *> *))
//   MRMediaRemoteGetNowPlayingInfoForClient(client, NULL, 0, queue, ^(CFDictionaryRef))
//
// ⚠️ 第二个是**五个参数**,中间两个传空。三参数版本会当场段错误 —— 这不是猜的:反汇编它的函数
// 序言,x0~x4 五个寄存器全被保存,x3/x4 还各被送进一次 retain/copy(queue 与 block)。
//
// ## 为什么必须被 /usr/bin/perl 加载
//
// 这些私有接口只对**有权限的进程**回话:自己编译的可执行文件调 `MRMediaRemoteGetNowPlayingApplicationPID`
// 返回 0(函数能调、拿不到数据),同样的调用放进 `/usr/bin/perl`(Apple 平台二进制)用 DynaLoader
// 加载的 dylib 里就拿到真值。这跟 media-control 自己要绕一层 perl 是同一个原因。
//
// 输出:一行 JSON。给了 bundle id 就只输出那一个(拿不到则 `null`),没给就输出全部,便于诊断。
//
// ## 待播队列(`LYRIMUSE_NOWPLAYING_QUEUE=N`,必须同时给 bundle id)
//
//   MRPlaybackQueueRequestCreate(location, length)       location 相对当前这首:0 = 当前这首
//   MRPlaybackQueueRequestSetIncludeMetadata(request, 1)
//   MRMediaRemoteRequestNowPlayingPlaybackQueue(request, client, origin, queue, ^(playbackQueue, error))
//   MRPlaybackQueueCopyContentItems(playbackQueue) → 每项 MRContentItemCopyNowPlayingInfo
//
// 请求那个也是**五个参数**:反汇编它的函数序言,x1 / x2 被拿去拼一个播放器路径(client、origin),
// x3 / x4 各被 retain / copy 一次(queue 与 block)。按 client 问就不受系统焦点被别的 App 抢走的影响。
// 输出 `{"items":[{title, artist, album, duration, identifier}…]}`,第一项是当前这首,供调用方核对。
// 实测只有 Apple Music 真的给队列(打乱之后的真实顺序,一次最多 40 首左右);Spotify / 酷狗只给当前这一首。

#import <Foundation/Foundation.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <dispatch/dispatch.h>

typedef void (*GetClientsFn)(dispatch_queue_t, void (^)(NSArray *));
typedef void (*GetInfoForClientFn)(void *, void *, long, dispatch_queue_t, void (^)(CFDictionaryRef));

/// 第三个参数是"要不要连封面数据一起给"的开关(实测:0 只给 ArtworkIdentifier / MIMEType /
/// 原图尺寸,≥1 才附 `ArtworkData`)。⚠️ 带上封面这一趟明显更贵(一份 JPEG 走 base64 过 JSON),
/// 所以**只在调用方明确要封面时**才置 1 —— 常规的状态查询不该每拍背一张图。
/// ⚠️ 给不给还取决于**这一刻在放什么**:实测五家都给(汽水音乐 9KB、QQ音乐 113KB、Spotify 107KB、
/// Apple Music 113KB),但 Spotify **放广告时不给** —— 一开始据此误判成"Spotify 不给封面",
/// 换成真歌再测就有了。浏览器里的视频也不给。拿不到就是拿不到,调用方照旧退回既有来源。
static const long kIncludeArtwork = 1;
static const long kNoArtwork = 0;

static NSString *K(const char *suffix) {
    return [NSString stringWithFormat:@"kMRMediaRemoteNowPlayingInfo%s", suffix];
}

/// 把一份 MediaRemote 载荷整理成与 media-control 输出同构的字典。
/// 位置按锚点外推:`elapsed + (now - timestamp) * rate` —— 载荷里的 ElapsedTime 是**锚点**,
/// 不是此刻的位置(同一首歌里连查几次它一动不动)。锚点原值一并带出,供上层判"这是不是开播锚点"。
static NSDictionary *normalize(NSDictionary *raw, NSString *bundleID) {
    if (raw.count == 0) return nil;
    NSNumber *elapsed = raw[K("ElapsedTime")];
    NSNumber *rate = raw[K("PlaybackRate")];
    NSDate *stamp = raw[K("Timestamp")];
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"bundleIdentifier"] = bundleID ?: @"";
    if (raw[K("Title")]) out[@"title"] = raw[K("Title")];
    if (raw[K("Artist")]) out[@"artist"] = raw[K("Artist")];
    if (raw[K("Album")]) out[@"album"] = raw[K("Album")];
    if (raw[K("Duration")]) out[@"duration"] = raw[K("Duration")];
    if (rate) out[@"playbackRate"] = rate;
    // ⚠️ 必须是 JSON 的 true/false:`@(expr)` 出来的是数字 1/0,Swift 的 JSONDecoder 解 Bool 会当场失败。
    out[@"playing"] = (rate.doubleValue > 0) ? @YES : @NO;
    // 语义同 media-control 那条路:"这是当前选定播放器的一份有效快照",不是"这是 Apple Music"。
    out[@"isMusicApp"] = @YES;
    if (elapsed) {
        out[@"anchorElapsedTime"] = elapsed;
        double live = elapsed.doubleValue;
        if (stamp && rate.doubleValue > 0) {
            live += [[NSDate date] timeIntervalSinceDate:stamp] * rate.doubleValue;
        }
        out[@"elapsedTime"] = @(live);
    }
    if (stamp) out[@"timestamp"] = @([stamp timeIntervalSince1970]);
    // 封面:载荷里是原始 JPEG/PNG 字节,走 base64 过 JSON(与 media-control 的 artworkData 同形)。
    NSData *art = raw[K("ArtworkData")];
    if ([art isKindOfClass:NSData.class] && art.length > 0) {
        out[@"artworkData"] = [art base64EncodedStringWithOptions:0];
        NSString *mime = raw[K("ArtworkMIMEType")];
        out[@"artworkMimeType"] = [mime isKindOfClass:NSString.class] ? mime : @"image/jpeg";
    }
    return out;
}

static void emit(id obj) {
    NSData *d = obj ? [NSJSONSerialization dataWithJSONObject:obj options:0 error:NULL] : nil;
    if (d) {
        fwrite(d.bytes, 1, d.length, stdout);
    } else {
        fputs("null", stdout);
    }
    fputc('\n', stdout);
    fflush(stdout);
}

void nowplaying_clients(void *my_perl, void *cv) {
    @autoreleasepool {
        const char *want = getenv("LYRIMUSE_NOWPLAYING_BUNDLE");
        const char *artEnv = getenv("LYRIMUSE_NOWPLAYING_ARTWORK");
        const long artFlag = (artEnv && artEnv[0] == '1') ? kIncludeArtwork : kNoArtwork;
        void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
        if (!h) { emit(nil); return; }
        GetClientsFn getClients = (GetClientsFn)dlsym(h, "MRMediaRemoteGetNowPlayingClients");
        GetInfoForClientFn getInfo = (GetInfoForClientFn)dlsym(h, "MRMediaRemoteGetNowPlayingInfoForClient");
        if (!getClients || !getInfo) { emit(nil); return; }

        dispatch_semaphore_t s = dispatch_semaphore_create(0);
        __block NSArray *clients = nil;
        getClients(dispatch_get_global_queue(0, 0), ^(NSArray *cs) {
            clients = cs;
            dispatch_semaphore_signal(s);
        });
        if (dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, 3LL * NSEC_PER_SEC)) != 0) {
            emit(nil); return;
        }

        NSMutableArray *all = [NSMutableArray array];
        for (id c in clients) {
            id bidObj = ((id (*)(id, SEL))objc_msgSend)(c, sel_getUid("bundleIdentifier"));
            NSString *bid = [bidObj isKindOfClass:NSString.class] ? bidObj : nil;
            if (want && (!bid || strcmp(bid.UTF8String, want) != 0)) continue;

            dispatch_semaphore_t s2 = dispatch_semaphore_create(0);
            __block NSDictionary *info = nil;
            getInfo((__bridge void *)c, NULL, artFlag, dispatch_get_global_queue(0, 0), ^(CFDictionaryRef raw) {
                if (raw) info = (__bridge_transfer NSDictionary *)CFRetain(raw);
                dispatch_semaphore_signal(s2);
            });
            if (dispatch_semaphore_wait(s2, dispatch_time(DISPATCH_TIME_NOW, 3LL * NSEC_PER_SEC)) != 0) continue;
            NSDictionary *one = normalize(info, bid);
            if (one) [all addObject:one];
        }
        emit(want ? (all.firstObject ?: (id)nil) : all);
    }
}

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
// client、origin、queue、callback;播放状态与元数据速率是独立的系统读数。
typedef void (*GetPlaybackStateForClientFn)(void *, void *, dispatch_queue_t, void (^)(uint32_t));
typedef void *(*QueueRequestCreateFn)(long, long);
typedef void (*QueueRequestSetBoolFn)(void *, int);
typedef void (*RequestQueueFn)(void *, void *, void *, dispatch_queue_t, void (^)(void *, CFErrorRef));
typedef CFArrayRef (*QueueCopyItemsFn)(void *);
typedef CFDictionaryRef (*ItemCopyInfoFn)(void *);
typedef CFStringRef (*ItemGetIdentifierFn)(void *);

/// 第三个参数是"要不要连封面数据一起给"的开关(实测:0 只给 ArtworkIdentifier / MIMEType /
/// 原图尺寸,≥1 才附 `ArtworkData`)。⚠️ 带上封面这一趟明显更贵(一份 JPEG 走 base64 过 JSON),
/// 所以**只在调用方明确要封面时**才置 1 —— 常规的状态查询不该每拍背一张图。
/// ⚠️ 给不给还取决于**这一刻在放什么**:实测五家都给(汽水音乐 9KB、QQ音乐 113KB、Spotify 107KB、
/// Apple Music 113KB),但 Spotify **放广告时不给** —— 一开始据此误判成"Spotify 不给封面",
/// 换成真歌再测就有了。浏览器里的视频也不给。拿不到就是拿不到,调用方照旧退回既有来源。
/// 状态查询那两段等待(取播放器列表、取单个播放器的信息)各等多久。两个调用方(App 的 NowPlayingClientsProbe、
/// collector 的 focusfallback.go)都在 2 秒整体超时后杀掉这个进程,原来每段 3 秒,MediaRemote 一慢这条路就永远拿不到
/// 结果;两段加起来要留在 2 秒以内。正常一次约 120ms。
static const int64_t kStateWaitMs = 900;
static const long kIncludeArtwork = 1;
static const long kNoArtwork = 0;

static NSString *K(const char *suffix) {
    return [NSString stringWithFormat:@"kMRMediaRemoteNowPlayingInfo%s", suffix];
}

/// Unknown / Seeking 不代表暂停,也不能按可能残留的速率猜成播放。
/// rate-playing 仅供共享播放器表明确准入的暂停态兼容;停止与中断不使用它。
static NSNumber *playingForState(uint32_t state, NSNumber *rate, BOOL playingFromRate) {
    switch (state) {
        case 1: return @YES;
        case 2: return playingFromRate && rate.doubleValue > 0 ? @YES : @NO;
        case 3:
        case 4: return @NO;
        default: return nil;
    }
}

/// 把同一 client 的元数据与可信状态整理成快照。暂停不外推,不能用残留 PlaybackRate 复活。
/// playing 为 nil 只用于独立封面查询,不生成播放状态。now 可注入,让冻结与外推的测试不依赖墙钟。
static NSDictionary *normalize(NSDictionary *raw, NSString *bundleID, NSNumber *playing, NSDate *now) {
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
    // 必须是 JSON 布尔值,Swift 的 JSONDecoder 不把数字 1/0 当 Bool。
    if (playing) out[@"playing"] = playing.boolValue ? @YES : @NO;
    // 语义同 media-control 那条路:"这是当前选定播放器的一份有效快照",不是"这是 Apple Music"。
    out[@"isMusicApp"] = @YES;
    if (elapsed) {
        out[@"anchorElapsedTime"] = elapsed;
        double live = elapsed.doubleValue;
        double speed = rate ? rate.doubleValue : 1;
        if (playing.boolValue && stamp && speed > 0) {
            live += [now timeIntervalSinceDate:stamp] * speed;
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

/// 元数据与状态并发查询,共用同一个截止时间,避免把两段等待串成超过外层超时的请求。
/// 封面查询不需要播放状态,不因状态接口缺失而失败。
static NSDictionary *clientSnapshot(id client, NSString *bundleID, long artFlag, BOOL playingFromRate,
                                    GetInfoForClientFn getInfo, GetPlaybackStateForClientFn getState,
                                    dispatch_time_t deadline) {
    BOOL needsState = artFlag == kNoArtwork;
    if (needsState && !getState) return nil;
    dispatch_queue_t queue = dispatch_get_global_queue(0, 0);
    dispatch_group_t group = dispatch_group_create();
    __block NSDictionary *info = nil;
    __block uint32_t state = 0;
    dispatch_group_enter(group);
    getInfo((__bridge void *)client, NULL, artFlag, queue, ^(CFDictionaryRef raw) {
        if (raw) info = [(__bridge NSDictionary *)raw copy];
        dispatch_group_leave(group);
    });
    if (needsState) {
        dispatch_group_enter(group);
        getState((__bridge void *)client, NULL, queue, ^(uint32_t value) {
            state = value;
            dispatch_group_leave(group);
        });
    }
    if (dispatch_group_wait(group, deadline) != 0) return nil;
    NSNumber *playing = needsState ? playingForState(state, info[K("PlaybackRate")], playingFromRate) : nil;
    if (needsState && !playing) return nil;
    return normalize(info, bundleID, playing, [NSDate date]);
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

/// 这个 client 的待播队列:当前这首 + 之后 `count` 首。拿不到返回 nil。
static NSDictionary *playbackQueue(void *h, id client, long count) {
    QueueRequestCreateFn create = (QueueRequestCreateFn)dlsym(h, "MRPlaybackQueueRequestCreate");
    QueueRequestSetBoolFn setMeta = (QueueRequestSetBoolFn)dlsym(h, "MRPlaybackQueueRequestSetIncludeMetadata");
    RequestQueueFn request = (RequestQueueFn)dlsym(h, "MRMediaRemoteRequestNowPlayingPlaybackQueue");
    QueueCopyItemsFn copyItems = (QueueCopyItemsFn)dlsym(h, "MRPlaybackQueueCopyContentItems");
    ItemCopyInfoFn copyInfo = (ItemCopyInfoFn)dlsym(h, "MRContentItemCopyNowPlayingInfo");
    ItemGetIdentifierFn getID = (ItemGetIdentifierFn)dlsym(h, "MRContentItemGetIdentifier");
    if (!create || !setMeta || !request || !copyItems || !copyInfo) return nil;
    void *req = create(0, count + 1);
    if (!req) return nil;
    setMeta(req, 1);
    dispatch_semaphore_t s = dispatch_semaphore_create(0);
    __block void *pq = NULL;
    request(req, (__bridge void *)client, NULL, dispatch_get_global_queue(0, 0), ^(void *q, CFErrorRef err) {
        if (q) pq = (void *)CFRetain(q);
        dispatch_semaphore_signal(s);
    });
    CFRelease(req);
    if (dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, 3LL * NSEC_PER_SEC)) != 0) return nil;
    if (!pq) return nil;
    NSArray *contentItems = (__bridge_transfer NSArray *)copyItems(pq);
    CFRelease(pq);
    NSMutableArray *items = [NSMutableArray array];
    for (id item in contentItems) {
        NSDictionary *info = (__bridge_transfer NSDictionary *)copyInfo((__bridge void *)item);
        NSMutableDictionary *one = [NSMutableDictionary dictionary];
        if ([info[K("Title")] isKindOfClass:NSString.class]) one[@"title"] = info[K("Title")];
        if ([info[K("Artist")] isKindOfClass:NSString.class]) one[@"artist"] = info[K("Artist")];
        if ([info[K("Album")] isKindOfClass:NSString.class]) one[@"album"] = info[K("Album")];
        if ([info[K("Duration")] isKindOfClass:NSNumber.class]) one[@"duration"] = info[K("Duration")];
        NSString *identifier = getID ? (__bridge NSString *)getID((__bridge void *)item) : nil;
        if ([identifier isKindOfClass:NSString.class]) one[@"identifier"] = identifier;
        [items addObject:one];
    }
    return @{@"items": items};
}

void nowplaying_clients(void *my_perl, void *cv) {
    @autoreleasepool {
        const char *want = getenv("LYRIMUSE_NOWPLAYING_BUNDLE");
        const char *artEnv = getenv("LYRIMUSE_NOWPLAYING_ARTWORK");
        const long artFlag = (artEnv && artEnv[0] == '1') ? kIncludeArtwork : kNoArtwork;
        const char *rateEnv = getenv("LYRIMUSE_NOWPLAYING_RATE_PLAYING");
        const BOOL playingFromRate = rateEnv && rateEnv[0] == '1';
        const char *queueEnv = getenv("LYRIMUSE_NOWPLAYING_QUEUE");
        const long queueCount = queueEnv ? atol(queueEnv) : 0;
        void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
        if (!h) { emit(nil); return; }
        GetClientsFn getClients = (GetClientsFn)dlsym(h, "MRMediaRemoteGetNowPlayingClients");
        GetInfoForClientFn getInfo = (GetInfoForClientFn)dlsym(h, "MRMediaRemoteGetNowPlayingInfoForClient");
        GetPlaybackStateForClientFn getState = (GetPlaybackStateForClientFn)dlsym(h, "MRMediaRemoteGetPlaybackStateForClient");
        if (!getClients || !getInfo) { emit(nil); return; }

        dispatch_semaphore_t s = dispatch_semaphore_create(0);
        __block NSArray *clients = nil;
        getClients(dispatch_get_global_queue(0, 0), ^(NSArray *cs) {
            clients = cs;
            dispatch_semaphore_signal(s);
        });
        if (dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, kStateWaitMs * NSEC_PER_MSEC)) != 0) {
            emit(nil); return;
        }

        NSMutableArray *all = [NSMutableArray array];
        for (id c in clients) {
            id bidObj = ((id (*)(id, SEL))objc_msgSend)(c, sel_getUid("bundleIdentifier"));
            NSString *bid = [bidObj isKindOfClass:NSString.class] ? bidObj : nil;
            if (want && (!bid || strcmp(bid.UTF8String, want) != 0)) continue;
            if (want && queueCount > 0) {
                emit(playbackQueue(h, c, queueCount));
                return;
            }

            NSDictionary *one = clientSnapshot(c, bid, artFlag, playingFromRate, getInfo, getState,
                                              dispatch_time(DISPATCH_TIME_NOW, kStateWaitMs * NSEC_PER_MSEC));
            if (one) [all addObject:one];
        }
        emit(want ? (all.firstObject ?: (id)nil) : all);
    }
}

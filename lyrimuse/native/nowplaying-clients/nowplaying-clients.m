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
// 焦点被占时它只返回占用者,目标播放器的 path 直接从列表里消失。能用的是下面这几个。
//
// ## 三个接口与它们的签名
//
//   MRMediaRemoteGetNowPlayingClients(queue, ^(NSArray<MRClient *> *))
//   MRMediaRemoteGetNowPlayingInfoForClient(client, NULL, 0, queue, ^(CFDictionaryRef))
//   MRMediaRemoteGetPlaybackStateForClient(client, NULL, queue, ^(uint32_t))
//
// ⚠️ 第二个是**五个参数**,中间两个传空。三参数版本会当场段错误 —— 这不是猜的:反汇编它的函数
// 序言,x0~x4 五个寄存器全被保存,x3/x4 还各被送进一次 retain/copy(queue 与 block)。
//
// 第三个是这个 App 自己的播放状态码(见 `playingFor`),跟载荷里的 PlaybackRate 是两份独立的读数:播放器暂停以后
// PlaybackRate 可能还留着 1。四个参数,中间那个传空。
//
// ## 为什么必须被 /usr/bin/perl 加载
//
// 这些私有接口只对**有权限的进程**回话:自己编译的可执行文件调 `MRMediaRemoteGetNowPlayingApplicationPID`
// 返回 0(函数能调、拿不到数据),同样的调用放进 `/usr/bin/perl`(Apple 平台二进制)用 DynaLoader
// 加载的 dylib 里就拿到真值。这跟 media-control 自己要绕一层 perl 是同一个原因。
//
// 输出:一行 JSON。给了 bundle id 就只输出那一个(拿不到则 `null`),没给就输出全部(诊断、App 认 Kaset 内嵌网页的那份会话
// 用,见 `NowPlayingClientsProbe.allSessions`)。每一份带报它的进程号 `processIdentifier`,和替谁干活的
// `responsibleProcessIdentifier`:WebKit 的媒体进程(`com.apple.WebKit.GPU`)每个用到网页的 App 各有一个,bundle id 都一样,
// 只有负责进程分得出是哪个 App 的(`responsibility_get_pid_responsible_for_pid`,活动监视器把 GPU 进程算到宿主头上用的也是它)。
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
//
// ## 常驻盯一个 App 内嵌网页的会话(`LYRIMUSE_NOWPLAYING_WATCH=<bundle id>`)
//
// 不退出,每一轮先在客户端列表里按 bundle id 找到那个 App 自己那份、取它的进程号,再问负责进程是它的那份 WebKit 媒体
// 会话(在放时每 0.25 秒、没在放时每 0.5 秒一轮),跟上一次输出的不一样才输出一行(在不在放、速率、锚点、时长;没有这份
// 会话、那个 App 没在列表里都输出 `null`),见 `watchWebSession`。要连着盯的走这个模式,别隔一会儿起一次
// helper(两种的开销见 02 章决策 88)。App 用它盯 Kaset 的暂停 / 恢复(`KasetWebSessionWatcher`)。
//
// ## 定向发一次跳转(`LYRIMUSE_NOWPLAYING_SEEK=<秒>`,必须同时给 bundle id)
//
//   MRMediaRemoteSendCommandToApp(command, options, origin, bundleID, appOptions, queue, ^(error, statuses))
//
// **七个参数**:命令号 24 是跳到某一位置,`options` 里 `kMRMediaRemoteOptionPlaybackPosition` 给秒数,origin 用
// `MRMediaRemoteGetLocalOrigin()`,appOptions 传 0。发给这个 App 自己登记的那份会话,不看系统焦点在谁身上;目标不接这个
// 命令时它不报错、照样落到焦点上,所以只在焦点就是这个 App(或它内嵌网页那份会话)时用。输出一行
// `{"sent":true,"answered":true,"error":<错误码>}`(等不到回话时 answered 为 false),接口取不到输出 `null`。
// App 用它给 Kaset 发跳转,见 02 章决策 94。

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
typedef void (*SendCommandToAppFn)(uint32_t, CFDictionaryRef, void *, CFStringRef, uint32_t, dispatch_queue_t,
                                   void (^)(uint32_t, CFArrayRef));
typedef void *(*GetLocalOriginFn)(void);

/// 第三个参数是"要不要连封面数据一起给"的开关(实测:0 只给 ArtworkIdentifier / MIMEType /
/// 原图尺寸,≥1 才附 `ArtworkData`)。⚠️ 带上封面这一趟明显更贵(一份 JPEG 走 base64 过 JSON),
/// 所以**只在调用方明确要封面时**才置 1 —— 常规的状态查询不该每拍背一张图。
/// ⚠️ 给不给还取决于**这一刻在放什么**:实测五家都给(汽水音乐 9KB、QQ音乐 113KB、Spotify 107KB、
/// Apple Music 113KB),但 Spotify **放广告时不给** —— 一开始据此误判成"Spotify 不给封面",
/// 换成真歌再测就有了。浏览器里的视频也不给。拿不到就是拿不到,调用方照旧退回既有来源。
/// 状态查询那两段等待(取播放器列表、取单个播放器的信息和播放状态)各等多久。调用方(App 的 NowPlayingClientsProbe)
/// 在 2 秒整体超时后杀掉这个进程,两段加起来要留在 2 秒以内。正常一次约 120ms。
static const int64_t kStateWaitMs = 900;
/// 元数据回话之后,播放状态再等多久。两个请求同时发出,正常时状态跟元数据一起回来;状态接口卡住时,列表模式里每个 client
/// 都等满 kStateWaitMs 会把外层 2 秒的超时撑破(八个 client 就是七秒多)。
static const int64_t kStateAfterInfoWaitMs = 150;
/// watch 模式两次查询之间隔多久:在放时要尽快看到暂停;没在放时(暂停着可能一停几个小时)放慢。
static const useconds_t kWatchIntervalUs = 250000;
static const useconds_t kWatchIdleIntervalUs = 500000;
/// App 内嵌网页的媒体由这个进程替它报(每个用到网页的 App 各有一个,按负责进程分)。
static NSString *const kWebMediaBundleID = @"com.apple.WebKit.GPU";
static const long kIncludeArtwork = 1;
static const long kNoArtwork = 0;
/// MediaRemote 的「跳到某一位置」命令号(kMRMediaRemoteCommandSeekToPlaybackPosition)。
static const uint32_t kSeekToPlaybackPositionCommand = 24;

static NSString *K(const char *suffix) {
    return [NSString stringWithFormat:@"kMRMediaRemoteNowPlayingInfo%s", suffix];
}

/// 没读到播放状态(接口取不到、没按时回话)。
static const uint32_t kStateUnavailable = UINT32_MAX;

/// 这一份算不算在放(见 02 章决策 109)。播放状态码:1 在放、2 暂停、3 停止、4 中断;0 未知、5 拖动中和别的值说不准。
/// 报了暂停 / 停止 / 中断就不在放,PlaybackRate 残留的 1 不算数。报在放还要速率不是 0(速率为 0 是在加载、缓冲,
/// 声音没走起来),没给速率时信状态。状态说不准或没读到时只看速率。
/// playingFromRate 只给共享播放器表准入的播放器(酷狗单曲循环回到开头后报暂停、速率照走,见 02 章决策 44)。
static BOOL playingFor(uint32_t state, NSNumber *rate, BOOL playingFromRate) {
    BOOL advancing = rate.doubleValue > 0;
    switch (state) {
        case 1: return rate == nil || advancing;
        case 2: return playingFromRate && advancing;
        case 3:
        case 4: return NO;
        default: return advancing;
    }
}

/// 把同一 client 的元数据与 `playingFor` 的结论整理成快照。不在放就不外推。
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

/// 报这一份的进程号;拿不到为 0。
static int clientPID(id client) {
    SEL pidSel = sel_getUid("processIdentifier");
    if (![client respondsToSelector:pidSel]) return 0;
    return ((int (*)(id, SEL))objc_msgSend)(client, pidSel);
}

/// pid 替谁干活(见头注);拿不到为 0。
static int responsiblePID(int pid) {
    typedef int (*ResponsibleFn)(int);
    ResponsibleFn responsible = (ResponsibleFn)dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");
    return (responsible && pid > 0) ? responsible(pid) : 0;
}

/// 给整理好的一份带上进程号与负责进程(见头注)。拿不到就原样返回。
static NSDictionary *withProcess(NSDictionary *one, id client) {
    int pid = clientPID(client);
    if (pid <= 0) return one;
    NSMutableDictionary *out = [one mutableCopy];
    out[@"processIdentifier"] = @(pid);
    int owner = responsiblePID(pid);
    if (owner > 0) out[@"responsibleProcessIdentifier"] = @(owner);
    return out;
}

/// 元数据与播放状态同时问。元数据等到 deadline,没按时回话返回 nil,answered 置 NO(调用方要分清「没问到」和「这一份是空的」
/// 时传它,否则传 NULL)。播放状态在元数据回话之后最多再等 kStateAfterInfoWaitMs,没读到不算失败,按 kStateUnavailable 交给
/// `playingFor`;等不到时把 stateStalled 置 YES,同一次查询里后面的 client 不再问(调用方传同一个变量,不需要时传 NULL)。
/// 封面查询不问播放状态,快照里也没有 playing。
static NSDictionary *clientSnapshot(id client, NSString *bundleID, long artFlag, BOOL playingFromRate,
                                    GetInfoForClientFn getInfo, GetPlaybackStateForClientFn getState,
                                    dispatch_time_t deadline, BOOL *answered, BOOL *stateStalled) {
    BOOL needsState = artFlag == kNoArtwork;
    BOOL askState = needsState && getState && !(stateStalled && *stateStalled);
    dispatch_queue_t queue = dispatch_get_global_queue(0, 0);
    dispatch_semaphore_t infoDone = dispatch_semaphore_create(0);
    dispatch_semaphore_t stateDone = dispatch_semaphore_create(0);
    __block NSDictionary *info = nil;
    __block uint32_t state = kStateUnavailable;
    getInfo((__bridge void *)client, NULL, artFlag, queue, ^(CFDictionaryRef raw) {
        if (raw) info = [(__bridge NSDictionary *)raw copy];
        dispatch_semaphore_signal(infoDone);
    });
    if (askState) {
        getState((__bridge void *)client, NULL, queue, ^(uint32_t value) {
            state = value;
            dispatch_semaphore_signal(stateDone);
        });
    }
    if (dispatch_semaphore_wait(infoDone, deadline) != 0) {
        if (answered) *answered = NO;
        return nil;
    }
    if (answered) *answered = YES;
    uint32_t seen = kStateUnavailable;
    if (askState) {
        if (dispatch_semaphore_wait(stateDone, dispatch_time(DISPATCH_TIME_NOW, kStateAfterInfoWaitMs * NSEC_PER_MSEC)) == 0) {
            seen = state;
        } else if (stateStalled) {
            *stateStalled = YES;
        }
    }
    NSNumber *playing = needsState ? @(playingFor(seen, info[K("PlaybackRate")], playingFromRate)) : nil;
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

/// watch 模式一轮里,从负责进程对得上的那几份 WebKit 媒体会话里挑一份,在放的优先。有一份没按时回话就算这一轮没问到
/// (answered 置 NO,返回 nil);一份都没有返回 nil、answered 为 YES。
static NSDictionary *pickWebSession(NSArray *candidates, GetInfoForClientFn getInfo, GetPlaybackStateForClientFn getState,
                                    BOOL *answered) {
    NSDictionary *pick = nil;
    BOOL stateStalled = NO;
    for (id c in candidates) {
        BOOL ok = NO;
        NSDictionary *one = clientSnapshot(c, kWebMediaBundleID, kNoArtwork, NO, getInfo, getState,
                                           dispatch_time(DISPATCH_TIME_NOW, kStateWaitMs * NSEC_PER_MSEC), &ok, &stateStalled);
        if (!ok) {
            *answered = NO;
            return nil;
        }
        if (one && (!pick || ([one[@"playing"] boolValue] && ![pick[@"playing"] boolValue]))) pick = one;
    }
    *answered = YES;
    return pick;
}

/// watch 模式(见头注):进程号每一轮现找(那个 App 重启过也跟得上)。负责进程是它的 WebKit 媒体会话有好几份时在放的优先,
/// 挑法同 App 的 `KasetPlayerInfo.webMedia`。
/// 此刻进度(`elapsedTime`)每次都不一样,不输出。这一轮有哪一步没问到就不输出,别把没问到当成会话没了。父进程没了
/// (被 launchd 收养)就退出。
static void watchWebSession(GetClientsFn getClients, GetInfoForClientFn getInfo, GetPlaybackStateForClientFn getState,
                            NSString *ownerBundleID) {
    NSString *last = nil;
    BOOL playing = NO;
    while (getppid() != 1) {
        @autoreleasepool {
            dispatch_semaphore_t s = dispatch_semaphore_create(0);
            __block NSArray *clients = nil;
            getClients(dispatch_get_global_queue(0, 0), ^(NSArray *cs) {
                clients = cs;
                dispatch_semaphore_signal(s);
            });
            BOOL answered = dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, kStateWaitMs * NSEC_PER_MSEC)) == 0;
            int owner = 0;
            for (id c in (answered ? clients : nil)) {
                id bidObj = ((id (*)(id, SEL))objc_msgSend)(c, sel_getUid("bundleIdentifier"));
                if ([bidObj isKindOfClass:NSString.class] && [bidObj isEqualToString:ownerBundleID]) owner = clientPID(c);
            }
            NSMutableArray *candidates = [NSMutableArray array];
            for (id c in ((answered && owner > 0) ? clients : nil)) {
                id bidObj = ((id (*)(id, SEL))objc_msgSend)(c, sel_getUid("bundleIdentifier"));
                if (![bidObj isKindOfClass:NSString.class] || ![bidObj isEqualToString:kWebMediaBundleID]) continue;
                if (responsiblePID(clientPID(c)) != owner) continue;
                [candidates addObject:c];
            }
            NSDictionary *pick = answered ? pickWebSession(candidates, getInfo, getState, &answered) : nil;
            if (answered) {
                playing = [pick[@"playing"] boolValue];
                NSMutableDictionary *line = nil;
                if (pick) {
                    line = [NSMutableDictionary dictionary];
                    for (NSString *key in @[@"playing", @"playbackRate", @"anchorElapsedTime", @"timestamp", @"duration"]) {
                        if (pick[key]) line[key] = pick[key];
                    }
                }
                NSData *d = line ? [NSJSONSerialization dataWithJSONObject:line options:NSJSONWritingSortedKeys error:NULL] : nil;
                NSString *text = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"null";
                if (![text isEqualToString:last]) {
                    fputs(text.UTF8String, stdout);
                    fputc('\n', stdout);
                    fflush(stdout);
                    last = text;
                }
            }
        }
        usleep(playing ? kWatchIntervalUs : kWatchIdleIntervalUs);
    }
}

/// 定向给 `bundleID` 那个 App 发一次「跳到第几秒」(见头注)。接口取不到、秒数不对返回 nil。
static NSDictionary *sendSeek(void *h, NSString *bundleID, double seconds) {
    SendCommandToAppFn send = (SendCommandToAppFn)dlsym(h, "MRMediaRemoteSendCommandToApp");
    GetLocalOriginFn localOrigin = (GetLocalOriginFn)dlsym(h, "MRMediaRemoteGetLocalOrigin");
    CFStringRef *positionKey = (CFStringRef *)dlsym(h, "kMRMediaRemoteOptionPlaybackPosition");
    if (!send || !positionKey || !*positionKey || !(seconds >= 0)) return nil;
    NSDictionary *options = @{(__bridge NSString *)*positionKey: @(seconds)};
    dispatch_semaphore_t s = dispatch_semaphore_create(0);
    __block uint32_t error = UINT32_MAX;
    send(kSeekToPlaybackPositionCommand, (__bridge CFDictionaryRef)options, localOrigin ? localOrigin() : NULL,
         (__bridge CFStringRef)bundleID, 0, dispatch_get_global_queue(0, 0), ^(uint32_t e, CFArrayRef statuses) {
             error = e;
             dispatch_semaphore_signal(s);
         });
    if (dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, kStateWaitMs * NSEC_PER_MSEC)) != 0) {
        return @{@"sent": @YES, @"answered": @NO};
    }
    return @{@"sent": @YES, @"answered": @YES, @"error": @(error)};
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
        const char *watchEnv = getenv("LYRIMUSE_NOWPLAYING_WATCH");
        const char *seekEnv = getenv("LYRIMUSE_NOWPLAYING_SEEK");
        void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
        if (!h) { emit(nil); return; }
        if (seekEnv && seekEnv[0]) {
            emit(want ? sendSeek(h, [NSString stringWithUTF8String:want], atof(seekEnv)) : nil);
            return;
        }
        GetClientsFn getClients = (GetClientsFn)dlsym(h, "MRMediaRemoteGetNowPlayingClients");
        GetInfoForClientFn getInfo = (GetInfoForClientFn)dlsym(h, "MRMediaRemoteGetNowPlayingInfoForClient");
        GetPlaybackStateForClientFn getState = (GetPlaybackStateForClientFn)dlsym(h, "MRMediaRemoteGetPlaybackStateForClient");
        if (!getClients || !getInfo) { emit(nil); return; }
        if (watchEnv && watchEnv[0]) {
            watchWebSession(getClients, getInfo, getState, [NSString stringWithUTF8String:watchEnv]);
            return;
        }

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
        BOOL stateStalled = NO;
        for (id c in clients) {
            id bidObj = ((id (*)(id, SEL))objc_msgSend)(c, sel_getUid("bundleIdentifier"));
            NSString *bid = [bidObj isKindOfClass:NSString.class] ? bidObj : nil;
            if (want && (!bid || strcmp(bid.UTF8String, want) != 0)) continue;
            if (want && queueCount > 0) {
                emit(playbackQueue(h, c, queueCount));
                return;
            }

            NSDictionary *one = clientSnapshot(c, bid, artFlag, playingFromRate, getInfo, getState,
                                              dispatch_time(DISPATCH_TIME_NOW, kStateWaitMs * NSEC_PER_MSEC), NULL, &stateStalled);
            if (one) [all addObject:withProcess(one, c)];
        }
        emit(want ? (all.firstObject ?: (id)nil) : all);
    }
}

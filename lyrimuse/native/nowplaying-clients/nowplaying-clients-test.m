#import "nowplaying-clients.m"

static int checks = 0;
#define CHECK(value) do { checks++; if (!(value)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #value); exit(1); } } while (0)

static id expectedClient;
static NSDictionary *fixture;
static uint32_t fixtureState;
static int stateCalls;
static int infoCalls;

static void fakeInfo(void *client, void *origin, long artwork, dispatch_queue_t queue, void (^callback)(CFDictionaryRef)) {
    CHECK(client == (__bridge void *)expectedClient && origin == NULL);
    infoCalls++;
    callback((__bridge CFDictionaryRef)fixture);
}

static void fakeState(void *client, void *origin, dispatch_queue_t queue, void (^callback)(uint32_t)) {
    CHECK(client == (__bridge void *)expectedClient && origin == NULL);
    stateCalls++;
    callback(fixtureState);
}

static void stalledState(void *client, void *origin, dispatch_queue_t queue, void (^callback)(uint32_t)) {
    stateCalls++;
}

static void stalledInfo(void *client, void *origin, long artwork, dispatch_queue_t queue, void (^callback)(CFDictionaryRef)) {
    infoCalls++;
}

static void normalizationTests(void) {
    NSDate *stamp = [NSDate dateWithTimeIntervalSince1970:1790000000];
    NSDate *now = [stamp dateByAddingTimeInterval:60];
    NSDictionary *raw = @{K("Title"): @"Song", K("Artist"): @"Artist", K("Duration"): @232,
                          K("ElapsedTime"): @20, K("PlaybackRate"): @1, K("Timestamp"): stamp};
    // 同一份暂停后的旧速率不能因浏览器恢复而让目标播放器恢复外推。
    for (NSString *bundle in @[@"com.tencent.QQMusicMac", @"com.netease.163music", @"com.soda.music",
                               @"com.kkbox.electron-app", @"com.amazon.music", @"com.apple.Music", @"com.spotify.client"]) {
        for (uint32_t state = 2; state <= 4; state++) {
            NSNumber *playing = @(playingFor(state, @1, NO));
            NSDictionary *out = normalize(raw, bundle, playing, now);
            CHECK([out[@"playing"] isEqual:@NO]);
            CHECK([out[@"elapsedTime"] isEqual:@20]);
            CHECK([out[@"anchorElapsedTime"] isEqual:@20]);
            CHECK([out[@"bundleIdentifier"] isEqual:bundle]);
        }
    }
    NSDictionary *out = normalize(raw, @"com.tencent.QQMusicMac", @(playingFor(1, @1, NO)), now);
    CHECK([out[@"playing"] isEqual:@YES]);
    CHECK([out[@"elapsedTime"] isEqual:@80]);
    CHECK([out[@"anchorElapsedTime"] isEqual:@20]);
    NSMutableDictionary *changed = [raw mutableCopy];
    changed[K("PlaybackRate")] = @2;
    CHECK([normalize(changed, @"player", @YES, now)[@"elapsedTime"] isEqual:@140]);
    [changed removeObjectForKey:K("PlaybackRate")];
    CHECK([normalize(changed, @"player", @(playingFor(1, nil, NO)), now)[@"elapsedTime"] isEqual:@80]);

    // 报在放:速率为 0 是在加载、缓冲,不算在放;没给速率信状态。
    CHECK(playingFor(1, @1, NO) && playingFor(1, nil, NO) && !playingFor(1, @0, NO));
    // 只有准入的播放器在报暂停时看速率;停止、中断都不看。
    CHECK(playingFor(2, @1, YES));
    CHECK(!playingFor(2, @0, YES) && !playingFor(2, nil, YES));
    CHECK(!playingFor(3, @1, YES) && !playingFor(4, @1, YES));
    // 状态说不准(未知、拖动中、别的值)或没读到:只看速率,跟没有状态接口时一样。
    for (NSNumber *state in @[@0, @5, @99, @(kStateUnavailable)]) {
        for (NSNumber *compat in @[@NO, @YES]) {
            CHECK(playingFor(state.unsignedIntValue, @1, compat.boolValue));
            CHECK(!playingFor(state.unsignedIntValue, @0, compat.boolValue));
            CHECK(!playingFor(state.unsignedIntValue, nil, compat.boolValue));
        }
    }
    CHECK(normalize(@{}, @"player", @YES, now) == nil);
    NSString *json = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:
        normalize(raw, @"player", @NO, now) options:0 error:NULL] encoding:NSUTF8StringEncoding];
    CHECK([json containsString:@"\"playing\":false"]);
}

static void queryTests(void) {
    expectedClient = [NSObject new];
    fixture = @{K("Title"): @"Song", K("ElapsedTime"): @20, K("PlaybackRate"): @1,
                K("ArtworkData"): [@"image" dataUsingEncoding:NSUTF8StringEncoding], K("ArtworkMIMEType"): @"image/png"};
    fixtureState = 2;
    BOOL answered = NO;
    NSDictionary *out = clientSnapshot(expectedClient, @"com.tencent.QQMusicMac", kNoArtwork, NO,
                                      fakeInfo, fakeState, DISPATCH_TIME_NOW, &answered, NULL);
    CHECK([out[@"playing"] isEqual:@NO] && [out[@"elapsedTime"] isEqual:@20] && answered);
    CHECK(stateCalls == 1 && infoCalls == 1);
    // 状态说不准:照样给出快照,按速率判(载荷里速率是 1)。
    for (NSNumber *state in @[@0, @5, @99]) {
        fixtureState = state.unsignedIntValue;
        out = clientSnapshot(expectedClient, @"player", kNoArtwork, NO, fakeInfo, fakeState, DISPATCH_TIME_NOW, NULL, NULL);
        CHECK([out[@"playing"] isEqual:@YES] && [out[@"title"] isEqual:@"Song"]);
    }
    // 没有状态接口(老系统)、状态没按时回话:同样按速率判,不丢这一份。
    out = clientSnapshot(expectedClient, @"player", kNoArtwork, NO, fakeInfo, NULL, DISPATCH_TIME_NOW, NULL, NULL);
    CHECK([out[@"playing"] isEqual:@YES]);
    out = clientSnapshot(expectedClient, @"player", kNoArtwork, NO, fakeInfo, stalledState, DISPATCH_TIME_NOW, &answered, NULL);
    CHECK([out[@"playing"] isEqual:@YES] && answered);
    // 元数据没按时回话:没问到,跟「这一份是空的」分开报。
    answered = YES;
    CHECK(clientSnapshot(expectedClient, @"player", kNoArtwork, NO, stalledInfo, fakeState, DISPATCH_TIME_NOW, &answered, NULL) == nil);
    CHECK(!answered);
    NSDictionary *saved = fixture;
    fixture = nil;
    CHECK(clientSnapshot(expectedClient, @"player", kNoArtwork, NO, fakeInfo, fakeState, DISPATCH_TIME_NOW, &answered, NULL) == nil);
    CHECK(answered);
    fixture = saved;
    // 报暂停而速率残留 1:不在放;准入的播放器照旧按速率算在放。
    fixtureState = 2;
    CHECK([clientSnapshot(expectedClient, @"player", kNoArtwork, NO, fakeInfo, fakeState, DISPATCH_TIME_NOW, NULL, NULL)[@"playing"] isEqual:@NO]);
    CHECK([clientSnapshot(expectedClient, @"com.kugou.mac.Music", kNoArtwork, YES, fakeInfo, fakeState, DISPATCH_TIME_NOW, NULL, NULL)[@"playing"] isEqual:@YES]);
    // 状态卡住:元数据回话后最多再等 kStateAfterInfoWaitMs(截止时间给得再宽也不等满),按速率判,并记下卡住;
    // 同一次查询里后面的 client 不再问状态。
    BOOL stalled = NO;
    NSDate *started = [NSDate date];
    out = clientSnapshot(expectedClient, @"player", kNoArtwork, NO, fakeInfo, stalledState,
                         dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), NULL, &stalled);
    CHECK([[NSDate date] timeIntervalSinceDate:started] < 1.0);
    CHECK([out[@"playing"] isEqual:@YES] && stalled);
    int asked = stateCalls;
    fixtureState = 2;
    out = clientSnapshot(expectedClient, @"player", kNoArtwork, NO, fakeInfo, fakeState, DISPATCH_TIME_NOW, NULL, &stalled);
    CHECK(stateCalls == asked && [out[@"playing"] isEqual:@YES]);
    stalled = NO;
    out = clientSnapshot(expectedClient, @"player", kNoArtwork, NO, fakeInfo, fakeState, DISPATCH_TIME_NOW, NULL, &stalled);
    CHECK(stateCalls == asked + 1 && [out[@"playing"] isEqual:@NO] && !stalled);
    // watch 模式每一轮重新问状态:上一轮卡住不影响这一轮。
    BOOL roundOK = NO;
    CHECK(pickWebSession(@[expectedClient], fakeInfo, stalledState, &roundOK) != nil && roundOK);
    asked = stateCalls;
    CHECK([pickWebSession(@[expectedClient], fakeInfo, fakeState, &roundOK)[@"playing"] isEqual:@NO] && stateCalls == asked + 1);
    // watch 模式挑会话:报暂停、速率残留 1 的那份不算在放;在放的优先;有一份没按时回话就算这一轮没问到。
    BOOL ok = NO;
    CHECK([pickWebSession(@[expectedClient], fakeInfo, fakeState, &ok)[@"playing"] isEqual:@NO] && ok);
    fixtureState = 1;
    CHECK([pickWebSession(@[expectedClient, expectedClient], fakeInfo, fakeState, &ok)[@"playing"] isEqual:@YES] && ok);
    CHECK(pickWebSession(@[expectedClient], stalledInfo, fakeState, &ok) == nil && !ok);
    CHECK(pickWebSession(@[], fakeInfo, fakeState, &ok) == nil && ok);
    fixtureState = 2;
    int before;

    // 封面不需要播放状态符号,仍给出同一曲目的图片与 MIMEType。
    before = stateCalls;
    out = clientSnapshot(expectedClient, @"player", kIncludeArtwork, NO, fakeInfo, NULL, DISPATCH_TIME_NOW, NULL, NULL);
    CHECK([out[@"artworkData"] isEqual:@"aW1hZ2U="]);
    CHECK([out[@"artworkMimeType"] isEqual:@"image/png"]);
    CHECK([out[@"title"] isEqual:@"Song"]);
    CHECK(stateCalls == before && out[@"playing"] == nil);
}

int main(void) {
    @autoreleasepool {
        normalizationTests();
        queryTests();
        printf("nowplaying-clients: %d checks ALL PASS\n", checks);
    }
    return 0;
}

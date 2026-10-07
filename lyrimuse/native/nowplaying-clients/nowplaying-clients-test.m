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
            NSNumber *playing = playingForState(state, @1, NO);
            NSDictionary *out = normalize(raw, bundle, playing, now);
            CHECK([out[@"playing"] isEqual:@NO]);
            CHECK([out[@"elapsedTime"] isEqual:@20]);
            CHECK([out[@"anchorElapsedTime"] isEqual:@20]);
            CHECK([out[@"bundleIdentifier"] isEqual:bundle]);
        }
    }
    NSDictionary *out = normalize(raw, @"com.tencent.QQMusicMac", playingForState(1, @1, NO), now);
    CHECK([out[@"playing"] isEqual:@YES]);
    CHECK([out[@"elapsedTime"] isEqual:@80]);
    CHECK([out[@"anchorElapsedTime"] isEqual:@20]);
    NSMutableDictionary *changed = [raw mutableCopy];
    changed[K("PlaybackRate")] = @2;
    CHECK([normalize(changed, @"player", @YES, now)[@"elapsedTime"] isEqual:@140]);
    [changed removeObjectForKey:K("PlaybackRate")];
    CHECK([normalize(changed, @"player", playingForState(1, nil, NO), now)[@"elapsedTime"] isEqual:@80]);

    // 只有已准入的已知暂停态使用速率兼容;Unknown / Seeking / stopped 不复活。
    CHECK([playingForState(2, @1, YES) isEqual:@YES]);
    CHECK([playingForState(2, @0, YES) isEqual:@NO]);
    CHECK([playingForState(3, @1, YES) isEqual:@NO]);
    CHECK([playingForState(4, @1, YES) isEqual:@NO]);
    for (NSNumber *state in @[@0, @5, @99]) {
        CHECK(playingForState(state.unsignedIntValue, @1, NO) == nil);
        CHECK(playingForState(state.unsignedIntValue, @1, YES) == nil);
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
    NSDictionary *out = clientSnapshot(expectedClient, @"com.tencent.QQMusicMac", kNoArtwork, NO,
                                      fakeInfo, fakeState, DISPATCH_TIME_NOW);
    CHECK([out[@"playing"] isEqual:@NO] && [out[@"elapsedTime"] isEqual:@20]);
    CHECK(stateCalls == 1 && infoCalls == 1);
    for (NSNumber *state in @[@0, @5, @99]) {
        fixtureState = state.unsignedIntValue;
        CHECK(clientSnapshot(expectedClient, @"player", kNoArtwork, YES, fakeInfo, fakeState, DISPATCH_TIME_NOW) == nil);
    }
    int before = infoCalls;
    CHECK(clientSnapshot(expectedClient, @"player", kNoArtwork, NO, fakeInfo, NULL, DISPATCH_TIME_NOW) == nil);
    CHECK(infoCalls == before);
    CHECK(clientSnapshot(expectedClient, @"player", kNoArtwork, NO, fakeInfo, stalledState, DISPATCH_TIME_NOW) == nil);
    CHECK(clientSnapshot(expectedClient, @"player", kNoArtwork, NO, stalledInfo, fakeState, DISPATCH_TIME_NOW) == nil);

    // 封面不需要播放状态符号,仍给出同一曲目的图片与 MIMEType。
    before = stateCalls;
    out = clientSnapshot(expectedClient, @"player", kIncludeArtwork, NO, fakeInfo, NULL, DISPATCH_TIME_NOW);
    CHECK([out[@"artworkData"] isEqual:@"aW1hZ2U="]);
    CHECK([out[@"artworkMimeType"] isEqual:@"image/png"]);
    CHECK([out[@"title"] isEqual:@"Song"]);
    CHECK(stateCalls == before);
}

int main(void) {
    @autoreleasepool {
        normalizationTests();
        queryTests();
        printf("nowplaying-clients: %d checks ALL PASS\n", checks);
    }
    return 0;
}

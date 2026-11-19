//
//  FCNet.m —— 进程内网络取证 / 重写 / 拦截（v52）
//  设计说明见 FCNet.h 顶部注释。
//
//  几条硬约束（都是真机上踩过的）：
//   1. 绝不在 canInitWithRequest: 里做重活——UIKit 会为每个请求调用它，且可能在任意线程。
//   2. 接管后自己发请求，必须给 request 打标记，否则 NSURLSession 会再次进 canInitWithRequest
//      → 无限递归（真机上表现为请求全部卡死、CPU 100%）。
//   3. 记录必须裁剪：body 单条限 256KB、总条数限 100，否则大文件下载会把内存吃爆。
//   4. 所有改写只在「命中用户规则」时发生，没命中就完全透传——这是「不影响正常网络」的底线。
//
#import "FCNet.h"
#import <objc/runtime.h>

#pragma mark - 全局状态

static BOOL gNetOn = NO;
static NSMutableArray<FCNetRecord *> *gRecords = nil;
static NSUInteger gNetRid = 0;
static NSMutableArray<NSDictionary *> *gRuleCache = nil;      // 与 NSUserDefaults 同步的镜像
static NSMutableDictionary<NSString *, NSRegularExpression *> *gRegexCache = nil;

// v52：并发保护。canInitWithRequest: / dataTask 回调可能在任意线程，
// 而 gRecords / gRuleCache / gRegexCache 都是非线程安全的可变容器——
// 不加锁在真机上就是「用一会儿莫名闪退」。统一走这一把锁。
static NSObject *FCNetLock(void) {
    static NSObject *lock = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

static NSString * const kFCNetEnabledKey = @"FCNetEnabled_v1";
static NSString * const kFCNetRulesKey   = @"FCNetRules_v1";
static NSString * const kFCNetHandled    = @"FCNetHandled";      // request 标记，防递归

static const NSUInteger kMaxRecords   = 100;
static const NSUInteger kMaxBodyBytes = 256 * 1024;

#pragma mark - 记录对象

@implementation FCNetRecord
- (NSString *)description {
    return [NSString stringWithFormat:@"%@ %@ -> %ld (%.0fms, %@)",
            self.method, self.path, (long)self.status, self.cost * 1000, self.source];
}
@end

#pragma mark - 工具

static NSData *FCNetClip(NSData *d) {
    if (!d.length) return nil;
    if (d.length <= kMaxBodyBytes) return d;
    return [d subdataWithRange:NSMakeRange(0, kMaxBodyBytes)];
}

// header 字典的值可能是 NSNumber/NSArray（CFNetwork 会这样给），统一转字符串
static NSDictionary<NSString *, NSString *> *FCNetHeaders(NSDictionary *raw) {
    if (![raw isKindOfClass:[NSDictionary class]] || !raw.count) return nil;
    NSMutableDictionary *out = [NSMutableDictionary dictionaryWithCapacity:raw.count];
    for (id k in raw) {
        id v = raw[k];
        NSString *ks = [k isKindOfClass:[NSString class]] ? k : [k description];
        NSString *vs = [v isKindOfClass:[NSString class]] ? v : [v description];
        if (ks.length) out[ks] = vs.length ? vs : @"";
    }
    return out;
}

static void FCNetPushRecord(FCNetRecord *rec) {
    if (!rec) return;
    @synchronized (FCNetLock()) {
        if (!gRecords) gRecords = [NSMutableArray array];
        rec.rid = ++gNetRid;
        [gRecords addObject:rec];
        if (gRecords.count > kMaxRecords)
            [gRecords removeObjectsInRange:NSMakeRange(0, gRecords.count - kMaxRecords)];
    }
    // 面板开着就顺手刷一下（节流由面板自己做）。放锁外面——刷面板要读记录，锁里调会自锁。
    FCNetRefreshPanelIfVisible();
}

static NSRegularExpression *FCNetRegex(NSString *pattern) {
    if (!pattern.length) return nil;
    @synchronized (FCNetLock()) {
        if (!gRegexCache) gRegexCache = [NSMutableDictionary dictionary];
        NSRegularExpression *re = gRegexCache[pattern];
        if (re) return re;
        NSError *err = nil;
        re = [NSRegularExpression regularExpressionWithPattern:pattern
                                                      options:NSRegularExpressionCaseInsensitive
                                                        error:&err];
        if (!re) return nil;
        gRegexCache[pattern] = re;
        return re;
    }
}

#pragma mark - 规则引擎

// 规则结构（全部可选，缺省即「不匹配 / 不动作」）：
//   url      正则，匹配完整 URL
//   method   GET / POST / *（缺省 *）
//   enabled  @YES/@NO（缺省 YES）
//   block    @YES → 直接阻断
//   mock     字典 {status, headers, body} → 造一个假响应
//   reqHeadersSet    字典 → 覆盖请求头
//   reqHeadersRemove 数组 → 删除请求头
//   reqBodyFind/reqBodyReplace   请求体字符串替换
//   respHeadersSet   字典 → 覆盖响应头
//   respBodyFind/respBodyReplace 响应体字符串替换
static NSArray<NSDictionary *> *FCNetLoadRules(void) {
    @synchronized (FCNetLock()) {
        if (gRuleCache) return gRuleCache;
        NSArray *raw = [[NSUserDefaults standardUserDefaults] arrayForKey:kFCNetRulesKey];
        NSMutableArray *a = [NSMutableArray array];
        for (id o in raw) if ([o isKindOfClass:[NSDictionary class]]) [a addObject:o];
        // 一次性赋值：读端要么看到旧数组、要么看到新数组，永远不会看到「加了一半」的
        gRuleCache = a;
        return gRuleCache;
    }
}

NSArray<NSDictionary *> *FCNetRules(void) { return [FCNetLoadRules() copy]; }

void FCNetSetRules(NSArray<NSDictionary *> *rules) {
    NSMutableArray *a = [NSMutableArray array];
    for (id o in rules) if ([o isKindOfClass:[NSDictionary class]]) [a addObject:o];
    @synchronized (FCNetLock()) { gRuleCache = a; }
    [[NSUserDefaults standardUserDefaults] setObject:a forKey:kFCNetRulesKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

void FCNetAddRule(NSDictionary *rule) {
    if (![rule isKindOfClass:[NSDictionary class]]) return;
    NSMutableArray *a = [NSMutableArray arrayWithArray:FCNetLoadRules()];
    [a addObject:rule];
    FCNetSetRules(a);
}

void FCNetRemoveRuleAtIndex(NSUInteger idx) {
    NSMutableArray *a = [NSMutableArray arrayWithArray:FCNetLoadRules()];
    if (idx >= a.count) return;
    [a removeObjectAtIndex:idx];
    FCNetSetRules(a);
}

NSString *FCNetRuleExplain(NSDictionary *rule) {
    if (![rule isKindOfClass:[NSDictionary class]]) return @"(无效规则)";
    NSMutableArray *parts = [NSMutableArray array];
    NSString *m = [rule[@"method"] isKindOfClass:[NSString class]] ? rule[@"method"] : nil;
    [parts addObject:(m.length ? m.uppercaseString : @"*")];
    NSString *u = [rule[@"url"] isKindOfClass:[NSString class]] ? rule[@"url"] : nil;
    [parts addObject:(u.length ? u : @"(任意 URL)")];
    NSMutableArray *acts = [NSMutableArray array];
    if ([rule[@"block"] boolValue]) [acts addObject:@"阻断"];
    if ([rule[@"mock"] isKindOfClass:[NSDictionary class]]) [acts addObject:@"伪造响应"];
    if ([rule[@"reqHeadersSet"] isKindOfClass:[NSDictionary class]]) [acts addObject:@"改请求头"];
    if ([rule[@"reqHeadersRemove"] isKindOfClass:[NSArray class]]) [acts addObject:@"删请求头"];
    if ([rule[@"reqBodyFind"] isKindOfClass:[NSString class]]) [acts addObject:@"改请求体"];
    if ([rule[@"respHeadersSet"] isKindOfClass:[NSDictionary class]]) [acts addObject:@"改响应头"];
    if ([rule[@"respBodyFind"] isKindOfClass:[NSString class]]) [acts addObject:@"改响应体"];
    NSString *name = [rule[@"name"] isKindOfClass:[NSString class]] ? rule[@"name"] : nil;
    NSString *tail = acts.count ? [acts componentsJoinedByString:@"/"] : @"(无动作)";
    return [NSString stringWithFormat:@"%@%@ → %@",
            name.length ? [name stringByAppendingString:@": "] : @"",
            [parts componentsJoinedByString:@" "], tail];
}

// 找第一条命中的启用规则；没命中返回 nil（= 完全透传）
static NSDictionary *FCNetRuleForRequest(NSURLRequest *req) {
    if (!req.URL) return nil;
    NSString *urlStr = req.URL.absoluteString;
    NSString *method = req.HTTPMethod.length ? req.HTTPMethod.uppercaseString : @"GET";
    for (NSDictionary *r in FCNetLoadRules()) {
        if ([r[@"enabled"] isKindOfClass:[NSNumber class]] && ![r[@"enabled"] boolValue]) continue;
        NSString *rm = [r[@"method"] isKindOfClass:[NSString class]] ? r[@"method"] : nil;
        if (rm.length && ![rm isEqualToString:@"*"] &&
            ![rm.uppercaseString isEqualToString:method]) continue;
        NSString *pattern = [r[@"url"] isKindOfClass:[NSString class]] ? r[@"url"] : nil;
        if (!pattern.length) return r;      // 没写 URL = 匹配全部（危险但用户明确要）
        NSRegularExpression *re = FCNetRegex(pattern);
        if (!re) continue;
        if ([re numberOfMatchesInString:urlStr options:0
                                  range:NSMakeRange(0, urlStr.length)] > 0) return r;
    }
    return nil;
}

#pragma mark - 采集

void FCNetSetEnabled(BOOL on) {
    gNetOn = on;
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kFCNetEnabledKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    if (on) {
        if (!gRecords) gRecords = [NSMutableArray array];
        // NSURLProtocol 注册是合法 API（不是 hook），Pure 档也能用
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            [NSURLProtocol registerClass:NSClassFromString(@"FCNetProtocol")];
        });
    } else {
        // 关掉采集不清记录——老大可能只是想停一下再看
    }
}

BOOL FCNetEnabled(void) { return gNetOn; }

NSArray<FCNetRecord *> *FCNetRecords(void) {
    @synchronized (FCNetLock()) { return gRecords ? [gRecords copy] : @[]; }
}
NSUInteger FCNetRecordCount(void) {
    @synchronized (FCNetLock()) { return gRecords.count; }
}

void FCNetClearRecords(void) {
    @synchronized (FCNetLock()) { [gRecords removeAllObjects]; }
    FCNetRefreshPanelIfVisible();
}

#pragma mark - NSURLProtocol 接管层（改写 / 伪造 / 阻断）

// 只在「命中规则」时接管。没命中一律 return NO 完全透传——这是不影响正常网络的前提。
@interface FCNetProtocol : NSURLProtocol
@property (nonatomic, strong) NSURLSessionDataTask *fcTask;
@property (nonatomic, assign) BOOL fcStopped;   // v52：已 stopLoading，回调里不再打扰 client
// 这两个方法定义在下面，这里先声明——否则 startLoading 里调用时编译器按 id 处理，
// applyResponseRules 返回 NSData* 会被当成 id，虽然能编过但类型丢了，容易埋坑。
- (void)applyRequestRules:(NSDictionary *)rule to:(NSMutableURLRequest *)m;
- (NSData *)applyResponseRules:(NSDictionary *)rule data:(NSData *)data
                          resp:(NSURLResponse *)resp rec:(FCNetRecord *)rec;
@end

@implementation FCNetProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if (!gNetOn) return NO;
    if (!request.URL) return NO;
    NSString *scheme = request.URL.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return NO;
    // 防递归：我们自己发出去的请求带着这个标记
    if ([NSURLProtocol propertyForKey:kFCNetHandled inRequest:request]) return NO;
    if (request.URL.absoluteString.length > 4000) return NO;
    return FCNetRuleForRequest(request) != nil;   // 只有需要改写才接管
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }

+ (BOOL)requestIsCacheEquivalent:(NSURLRequest *)a toRequest:(NSURLRequest *)b { return NO; }

- (void)stopLoading {
    self.fcStopped = YES;   // v52：先立标记，之后到达的回调一律丢弃
    if (self.fcTask) { [self.fcTask cancel]; self.fcTask = nil; }
}

- (void)startLoading {
    NSURLRequest *origin = self.request;
    NSDictionary *rule = FCNetRuleForRequest(origin);
    FCNetRecord *rec = [FCNetRecord new];
    rec.date = [NSDate date];
    rec.method = origin.HTTPMethod.length ? origin.HTTPMethod.uppercaseString : @"GET";
    rec.url = origin.URL.absoluteString;
    rec.host = origin.URL.host;
    rec.path = origin.URL.path.length ? origin.URL.path : @"/";
    rec.reqHeaders = FCNetHeaders([origin allHTTPHeaderFields]);
    rec.reqBody = FCNetClip(origin.HTTPBody);
    rec.source = @"协议";
    // v52：name 可能被存成非字符串（早期版本/手改配置），直接当 NSString 用会崩
    NSString *rname = [rule[@"name"] isKindOfClass:[NSString class]] ? rule[@"name"] : nil;
    rec.note = rule ? [@"命中: " stringByAppendingString:(rname.length ? rname : @"规则")] : nil;

    // ① 阻断
    if ([rule[@"block"] boolValue]) {
        rec.status = -1;
        rec.failed = YES;
        rec.errText = @"已被规则阻断";
        rec.note = @"已阻断";
        FCNetPushRecord(rec);
        NSError *e = [NSError errorWithDomain:@"FCNet" code:-999
                                     userInfo:@{NSLocalizedDescriptionKey: @"FCNet blocked"}];
        [self.client URLProtocol:self didFailWithError:e];
        return;
    }

    // ② 伪造响应
    NSDictionary *mock = rule[@"mock"];
    if ([mock isKindOfClass:[NSDictionary class]]) {
        NSInteger st = [mock[@"status"] integerValue] ?: 200;
        NSDictionary *hs = FCNetHeaders(mock[@"headers"]) ?: @{@"Content-Type": @"application/json"};
        NSString *bodyStr = mock[@"body"];
        NSData *body = [bodyStr isKindOfClass:[NSString class]]
            ? [bodyStr dataUsingEncoding:NSUTF8StringEncoding] : nil;
        NSHTTPURLResponse *resp = [[NSHTTPURLResponse alloc] initWithURL:origin.URL
                                                             statusCode:st
                                                            HTTPVersion:@"HTTP/1.1"
                                                           headerFields:hs];
        rec.status = st;
        rec.respHeaders = hs;
        rec.respBody = FCNetClip(body);
        rec.note = @"已伪造响应";
        rec.cost = 0;
        FCNetPushRecord(rec);
        [self.client URLProtocol:self didReceiveResponse:resp cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        if (body.length) [self.client URLProtocol:self didLoadData:body];
        [self.client URLProtocolDidFinishLoading:self];
        return;
    }

    // ③ 应用请求改写后自己发
    NSMutableURLRequest *m = [origin mutableCopy];
    [self applyRequestRules:rule to:m];
    [NSURLProtocol setProperty:@YES forKey:kFCNetHandled inRequest:m];

    NSTimeInterval t0 = CFAbsoluteTimeGetCurrent();
    __weak typeof(self) weakSelf = self;
    self.fcTask = [[NSURLSession sharedSession]
        dataTaskWithRequest:m
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            typeof(self) self_ = weakSelf;
            if (!self_) return;
            // v52：被 stopLoading 取消的请求，回调可能还在路上——此时再向 client 发消息
            // 会撞上已失效的协议实例（真机表现为偶发崩溃）。立过标记就直接丢。
            if (self_.fcStopped) return;
            rec.cost = CFAbsoluteTimeGetCurrent() - t0;
            if ([resp isKindOfClass:[NSHTTPURLResponse class]]) {
                NSHTTPURLResponse *hr = (NSHTTPURLResponse *)resp;
                rec.status = hr.statusCode;
                rec.respHeaders = FCNetHeaders([hr allHeaderFields]);
            }
            NSData *finalData = data;
            // ④ 响应改写（在回给 App 之前）
            NSData *rewritten = [self_ applyResponseRules:rule data:data resp:resp rec:rec];
            if (rewritten) finalData = rewritten;
            rec.respBody = FCNetClip(finalData);
            if (err) { rec.failed = YES; rec.errText = err.localizedDescription; }
            FCNetPushRecord(rec);

            if (err) {
                [self_.client URLProtocol:self_ didFailWithError:err];
                return;
            }
            if (resp) [self_.client URLProtocol:self_ didReceiveResponse:resp
                             cacheStoragePolicy:NSURLCacheStorageNotAllowed];
            if (finalData.length) [self_.client URLProtocol:self_ didLoadData:finalData];
            [self_.client URLProtocolDidFinishLoading:self_];
        }];
    if (self.fcTask) [self.fcTask resume];
}

- (void)applyRequestRules:(NSDictionary *)rule to:(NSMutableURLRequest *)m {
    if (![rule isKindOfClass:[NSDictionary class]]) return;
    NSDictionary *setH = rule[@"reqHeadersSet"];
    if ([setH isKindOfClass:[NSDictionary class]]) {
        for (NSString *k in setH) [m setValue:[setH[k] description] forHTTPHeaderField:k];
    }
    NSArray *rmH = rule[@"reqHeadersRemove"];
    if ([rmH isKindOfClass:[NSArray class]]) {
        for (id k in rmH) if ([k isKindOfClass:[NSString class]]) [m setValue:nil forHTTPHeaderField:k];
    }
    NSString *find = rule[@"reqBodyFind"];
    NSString *repl = rule[@"reqBodyReplace"];
    if ([find isKindOfClass:[NSString class]] && find.length && m.HTTPBody.length) {
        NSString *s = [[NSString alloc] initWithData:m.HTTPBody encoding:NSUTF8StringEncoding];
        if (s.length && [s containsString:find]) {
            NSString *ns = [s stringByReplacingOccurrencesOfString:find
                                                        withString:(repl ?: @"")];
            NSData *nd = [ns dataUsingEncoding:NSUTF8StringEncoding];
            if (nd) {
                m.HTTPBody = nd;
                [m setValue:[NSString stringWithFormat:@"%lu", (unsigned long)nd.length]
                    forHTTPHeaderField:@"Content-Length"];
            }
        }
    }
}

- (NSData *)applyResponseRules:(NSDictionary *)rule data:(NSData *)data
                          resp:(NSURLResponse *)resp rec:(FCNetRecord *)rec {
    if (![rule isKindOfClass:[NSDictionary class]] || !data.length) return nil;
    NSString *find = rule[@"respBodyFind"];
    NSString *repl = rule[@"respBodyReplace"];
    if (![find isKindOfClass:[NSString class]] || !find.length) return nil;
    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!s.length || ![s containsString:find]) return nil;
    NSString *ns = [s stringByReplacingOccurrencesOfString:find withString:(repl ?: @"")];
    // 注意：note 可能为空（没命中命名规则时），nil 上拼接会得到 nil、把原信息丢掉
    rec.note = rec.note.length ? [rec.note stringByAppendingString:@" / 已改响应体"]
                               : @"已改响应体";
    return [ns dataUsingEncoding:NSUTF8StringEncoding];
}

@end

#pragma mark - Deep 档：URLSession 采集（补上走 delegate 的请求）

#ifdef FC_DEEP_HOOKS

// v52：键是 NSValue(Method 指针)，不是 NSString——所以这里不能写
// NSMutableDictionary<NSString *, NSValue *>，那样 objectForKey: 只收 NSString，
// 传 NSValue 会直接 -Werror 编译失败。
static NSMutableDictionary *gOrigIMPs = nil;   // NSValue(Method) → NSValue(原 IMP)
static NSMutableSet *gHookedKeys = nil;

static BOOL FCNetHookMethod(Class cls, SEL sel, IMP tramp, NSUInteger argc) {
    if (!cls) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    if (!gOrigIMPs) gOrigIMPs = [NSMutableDictionary dictionary];
    NSValue *mk = [NSValue valueWithPointer:(void *)m];
    if ([gOrigIMPs objectForKey:mk]) return YES;
    if (!gHookedKeys) gHookedKeys = [NSMutableSet set];
    NSString *key = [NSString stringWithFormat:@"%s|%s", class_getName(cls), sel_getName(sel)];
    if ([gHookedKeys containsObject:key]) return YES;
    NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(m)];
    if (!sig || sig.numberOfArguments != argc) return NO;
    IMP orig = method_getImplementation(m);
    [gOrigIMPs setObject:[NSValue valueWithPointer:orig] forKey:mk];
    method_setImplementation(m, tramp);
    [gHookedKeys addObject:key];
    return YES;
}

static IMP FCNetOrigIMP(id self, SEL sel) {
    if (!gOrigIMPs) return NULL;
    Method m = class_getInstanceMethod(object_getClass(self), sel);
    if (!m) return NULL;
    NSValue *v = [gOrigIMPs objectForKey:[NSValue valueWithPointer:(void *)m]];
    return v ? (IMP)v.pointerValue : NULL;
}

// completionHandler 版本：包一层，拿到完整 data + response
static NSURLSessionDataTask *FCHookDataTaskCH(id self, SEL _cmd, NSURLRequest *req,
                                             void (^completion)(NSData *, NSURLResponse *, NSError *)) {
    IMP orig = FCNetOrigIMP(self, _cmd);
    if (!orig) return nil;
    if (!gNetOn || !req) {
        return ((NSURLSessionDataTask *(*)(id, SEL, NSURLRequest *, id))orig)(self, _cmd, req, completion);
    }
    // 命中改写规则时原样交给下层——让 NSURLProtocol 接管去改写/伪造/阻断。
    // 注意：这里**绝不能**打 kFCNetHandled 标记，打了 canInitWithRequest 就会跳过，规则失效。
    if (FCNetRuleForRequest(req)) {
        return ((NSURLSessionDataTask *(*)(id, SEL, NSURLRequest *, id))orig)(self, _cmd, req, completion);
    }
    NSString *method = req.HTTPMethod.length ? req.HTTPMethod.uppercaseString : @"GET";
    NSTimeInterval t0 = CFAbsoluteTimeGetCurrent();
    void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *d, NSURLResponse *r, NSError *e) {
        FCNetRecord *rec = [FCNetRecord new];
        rec.date = [NSDate date];
        rec.method = method;
        rec.url = req.URL.absoluteString;
        rec.host = req.URL.host;
        rec.path = req.URL.path.length ? req.URL.path : @"/";
        rec.reqHeaders = FCNetHeaders([req allHTTPHeaderFields]);
        rec.reqBody = FCNetClip(req.HTTPBody);
        rec.source = @"会话";
        rec.cost = CFAbsoluteTimeGetCurrent() - t0;
        if ([r isKindOfClass:[NSHTTPURLResponse class]]) {
            rec.status = ((NSHTTPURLResponse *)r).statusCode;
            rec.respHeaders = FCNetHeaders([((NSHTTPURLResponse *)r) allHeaderFields]);
        }
        rec.respBody = FCNetClip(d);
        if (e) { rec.failed = YES; rec.errText = e.localizedDescription; }
        FCNetPushRecord(rec);
        if (completion) completion(d, r, e);
    };
    return ((NSURLSessionDataTask *(*)(id, SEL, NSURLRequest *, id))orig)(self, _cmd, req, wrapped);
}

static NSURLSessionDataTask *FCHookDataTask(id self, SEL _cmd, NSURLRequest *req) {
    IMP orig = FCNetOrigIMP(self, _cmd);
    if (!orig) return nil;
    if (!gNetOn || !req)
        return ((NSURLSessionDataTask *(*)(id, SEL, NSURLRequest *))orig)(self, _cmd, req);
    if (FCNetRuleForRequest(req)) {
        // 同上：交给 NSURLProtocol 接管，不打标记
        return ((NSURLSessionDataTask *(*)(id, SEL, NSURLRequest *))orig)(self, _cmd, req);
    }
    // 走 delegate 的请求：这里只能记下请求侧，响应体靠 NSURLProtocol 旁听补不齐，
    // 所以在记录里明确标注「仅请求」，避免老大以为响应体是空的。
    FCNetRecord *rec = [FCNetRecord new];
    rec.date = [NSDate date];
    rec.method = req.HTTPMethod.length ? req.HTTPMethod.uppercaseString : @"GET";
    rec.url = req.URL.absoluteString;
    rec.host = req.URL.host;
    rec.path = req.URL.path.length ? req.URL.path : @"/";
    rec.reqHeaders = FCNetHeaders([req allHTTPHeaderFields]);
    rec.reqBody = FCNetClip(req.HTTPBody);
    rec.source = @"会话(delegate)";
    rec.note = @"仅请求侧（响应由 App 的 delegate 消费，未采集）";
    FCNetPushRecord(rec);
    return ((NSURLSessionDataTask *(*)(id, SEL, NSURLRequest *))orig)(self, _cmd, req);
}

static void FCNetInstallHooks(void) {
    Class sess = [NSURLSession class];
    BOOL a = FCNetHookMethod(sess, @selector(dataTaskWithRequest:completionHandler:),
                             (IMP)FCHookDataTaskCH, 4);
    BOOL b = FCNetHookMethod(sess, @selector(dataTaskWithRequest:), (IMP)FCHookDataTask, 3);
    NSLog(@"[FCAdBlock] 网络采集hook：completion=%@ 纯task=%@",
          a ? @"装" : @"无", b ? @"装" : @"无");
}

#endif  // FC_DEEP_HOOKS

#pragma mark - 对外：启动

void FCNetBootstrap(void) {
    gNetOn = [[NSUserDefaults standardUserDefaults] boolForKey:kFCNetEnabledKey];
    if (!gNetOn) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [NSURLProtocol registerClass:NSClassFromString(@"FCNetProtocol")];
    });
#ifdef FC_DEEP_HOOKS
    static dispatch_once_t once2;
    dispatch_once(&once2, ^{ FCNetInstallHooks(); });
#endif
}

NSString *FCNetSuggestedRuleForRecord(FCNetRecord *rec) {
    if (!rec.host.length) return nil;
    // 给「按域名整站」用的粗规则：路径里带 id 数字的容易变，退化成域名
    if (rec.path.length > 1 && rec.path.length < 120) {
        NSMutableString *p = [NSMutableString stringWithString:rec.path];
        // 把 6 位以上数字替换成 \d+，提高复用性
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"\\d{6,}"
                                                                          options:0 error:nil];
        [re replaceMatchesInString:p options:0 range:NSMakeRange(0, p.length)
                        withTemplate:@"\\\\d+"];
        return [NSString stringWithFormat:@"https?://%@%@", rec.host, p];
    }
    return [NSString stringWithFormat:@"https?://%@", rec.host];
}

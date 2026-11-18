//
//  FCAdBlockEntry.m —— 丰巢 (HiveConsumer) 去广告插件 v2
//
//  v2 相对 v1 的关键修复（针对真机反馈：开屏仍在、页面运营位没去掉）：
//    1) 取证结论：页面运营位文案（百元券包/寄件省钱卡/洗护券/换季洗羽绒）在整个
//       IPA 1208 个文件里 UTF-8/UTF-16LE 全部零命中 → 服务端 DSP 下发的 H5，
//       渲染在 WKWebView（二进制 WKWebView 201 处 + DCUni 295 处引用）。
//       原生视图树永远够不到 DOM → v2 新增 WKWebView JS 注入移除运营位卡片。
//    2) 开屏是真机截图里的京东面膜页，只有「跳过 2」没有「广告」角标，
//       v1 的 FCTextsAreAd 要求「广告角标 AND 动作」→ 判定失败从不点跳过。
//       v2 新增 FCTextsAreSplash 强特征（摇动或点击/跳转详情页/跳过+数字）。
//    3) 新增诊断浮标：窗口数/证据数/开屏命中/运营位证据/WebView数/H5命中/顶层VC，
//       一眼分清「没抓到」与「抓到了没处理」。
//
//  静态分析依据（丰巢 6.48.1 主二进制）：
//    uni-app + AWM/WindMill 聚合广告中台（穿山甲GroMore/GDT/KS/百度/趣盟/Sigmob）
//    宿主自有广告类 Swift（_TtC12HiveConsumer*，NSClassFromString 双命名兼容）
//
//  硬约束（严格遵守）：
//    1. 不 hook 任何系统类方法；WKWebView 只调用公开 API evaluateJavaScript，不是 hook
//    2. 不用 Logos / CydiaSubstrate，入口为纯 .m + constructor 构造函数
//    3. B 档只改宿主自有广告类自身方法，selector 匹配不到安全降级
//    4. A 档零 hook：定时视图扫描 + WKWebView JS 注入 + 公开 API 关闭
//    5. 类名/文案判定排除 "Adress/Address"（地址业务，丰巢核心功能）
//    6. 类名判定排除 "withdraw/提现" 等无关业务同形词
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#define FCLog(fmt, ...) NSLog((@"[FCAdBlock] " fmt), ##__VA_ARGS__)

#pragma mark - H5 运营位移除脚本

// 关键词来自真机截图红框内的独立文案，避免用「优惠券/福利」等通用词误伤正常功能。
// 脚本完全用单引号，零反斜杠、零双引号，避免 @"" 字面量提前闭合。
// MutationObserver 持续监听动态下发的运营位；__fcadLoaded 保证同 document 幂等。
static NSString * const FCJSAdCards =
@"(function(){var W=window;if(W.__fcadLoaded){if(W.__fcadSweep){W.__fcadSweep();}return;}"
"W.__fcadLoaded=1;W.__fcadHits=0;"
"var K=['百元券包','限量7折','寄件省钱卡','查价领返现','换季洗羽绒','任选3件'];"
"function hit(t){if(!t||t.length>160){return false;}"
"for(var i=0;i<K.length;i++){if(t.indexOf(K[i])>=0){return true;}}return false;}"
"function sweep(){var all=document.querySelectorAll('div,li,a,section,article');"
"for(var i=0;i<all.length;i++){var e=all[i];if(!e||e.__fcadDone){continue;}"
"var txt=(e.innerText||e.textContent||'');if(txt.length<2||txt.length>160){continue;}"
"if(!hit(txt)){continue;}"
"var t=e;for(var k=0;k<2;k++){var p=t.parentElement;if(!p||p===document.body){break;}"
"var pr=p.getBoundingClientRect();var tr=t.getBoundingClientRect();"
"if(tr.height>0&&pr.height<=tr.height*1.6&&pr.width<=window.innerWidth*0.96){t=p;}else{break;}}"
"var r=t.getBoundingClientRect();if(r.height>window.innerHeight*0.6){continue;}"
"t.style.setProperty('display','none','important');t.__fcadDone=1;W.__fcadHits=W.__fcadHits+1;}}"
"W.__fcadSweep=sweep;sweep();"
"if(document.documentElement&&!W.__fcadOb){W.__fcadOb=new MutationObserver(function(){sweep();});"
"W.__fcadOb.observe(document.documentElement,{childList:true,subtree:true});}})();";

#pragma mark - 运行计数（诊断浮标用）

static NSUInteger gFCWindows = 0;
static NSUInteger gFCEvidences = 0;
static NSUInteger gFCSplashHits = 0;
static NSUInteger gFCOpEvidence = 0;
static NSUInteger gFCWebViewFound = 0;
static NSUInteger gFCH5Hits = 0;

#pragma mark - 类名判定

static NSArray<NSString *> *FCAdClassKeys(void) {
    static NSArray *keys = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @[
            @"FCSplashADSManager", @"SplashAdManager", @"SplashAdLibHandler",
            @"NativeSplashAdView", @"SplashAdBottomView", @"SplashAdScreenShotManager",
            @"CheckOutAlertInsertADViewController", @"InterstScrAdLibTaku",
            @"InterstScrAdLibUBIX", @"OpenScrAdLibToBid", @"OpenScrAdLibUBIX",
            @"LifeServiceHomeADPopAlertView", @"DSPHomeAdsAlertView",
            @"SendOrderAdBannerView", @"BoxMobilePickADBannerView",
            @"BoxMobilePickADBannerLeftView", @"BoxMobilePickADBannerTopView",
            @"BoxMobilePickADBannerSuccessView",
            @"CheckoutAdFeedBannerCell", @"CheckoutAdFeedMixBannerCell",
            @"CheckoutAdFeedSepBannerCell", @"WashSOAdsView", @"WashSOAdsSectionView",
            @"LifeServiceDetailAdCell", @"WashImportSendAdsCell",
            @"CashDeskTakuADCell",
            @"AdCenter", @"AdsHandle", @"AdsCNManager",
        ];
    });
    return keys;
}

static BOOL FCIsExcludedClass(NSString *cls) {
    NSString *l = cls.lowercaseString;
    if ([l rangeOfString:@"adress"].location != NSNotFound) return YES;
    if ([l rangeOfString:@"address"].location != NSNotFound) return YES;
    if ([cls hasPrefix:@"_UI"] || [cls hasPrefix:@"UI"] || [cls hasPrefix:@"NS"] ||
        [cls isEqualToString:@"UIAlertController"] ||
        [cls isEqualToString:@"UIActivityViewController"] ||
        [cls hasPrefix:@"SFSafari"] || [cls hasPrefix:@"MFMail"] ||
        [cls hasPrefix:@"QLPreview"] || [cls isEqualToString:@"UILabel"]) return YES;
    return NO;
}

static BOOL FCClassIsAd(NSString *cls) {
    if (!cls.length || FCIsExcludedClass(cls)) return NO;
    for (NSString *k in FCAdClassKeys()) {
        if ([cls rangeOfString:k options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    // 单词级强特征（开屏/插屏），排除地址业务同形词
    NSString *l = cls.lowercaseString;
    if ([l rangeOfString:@"adress"].location == NSNotFound &&
        [l rangeOfString:@"address"].location == NSNotFound) {
        if ([l rangeOfString:@"splash"].location != NSNotFound ||
            [l rangeOfString:@"popupad"].location != NSNotFound ||
            [l rangeOfString:@"launchad"].location != NSNotFound ||
            [l rangeOfString:@"interstitial"].location != NSNotFound) return YES;
    }
    return NO;
}

static Class FCResolveClass(NSString *name) {
    Class c = NSClassFromString(name);
    if (c) return c;
    return NSClassFromString([@"HiveConsumer." stringByAppendingString:name]);
}

#pragma mark - 文案判定

// v1 原始判定：广告角标 + 动作组合（保留，处理激励广告）
static BOOL FCTextsAreAd(NSArray<NSString *> *texts) {
    BOOL hasAdTag = NO, hasAction = NO;
    for (NSString *raw in texts) {
        NSString *s = [raw stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (s.length == 0) continue;
        if ([s containsString:@"秒后可领奖励"] || [s containsString:@"后可领奖励"] ||
            [s containsString:@"跳过广告"] || [s containsString:@"看广告"] ||
            [s containsString:@"观看广告"] || [s containsString:@"看视频"] ||
            [s containsString:@"免广告"] || [s containsString:@"继续观看"] ||
            [s containsString:@"可获得奖励"] ||
            ([s containsString:@"再看"] && [s containsString:@"广告"])) return YES;
        if ([s isEqualToString:@"广告"] || [s isEqualToString:@"广告 |"] ||
            [s isEqualToString:@"广告｜"] ||
            ([s hasPrefix:@"广告"] && s.length <= 5)) hasAdTag = YES;
        if ([s containsString:@"立即购买"] || [s containsString:@"跳过"] ||
            [s containsString:@"领奖励"] || [s containsString:@"去领奖"] ||
            [s containsString:@"领取奖励"] || [s containsString:@"立即领取"]) hasAction = YES;
    }
    return hasAdTag && hasAction;
}

// v2 新增：开屏强特征。真机开屏只有「跳过 2」无「广告」角标，v1 因此漏判。
static BOOL FCTextsAreSplash(NSArray<NSString *> *texts) {
    for (NSString *raw in texts) {
        NSString *s = [raw stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([s containsString:@"摇动或点击"]) return YES;
        if ([s containsString:@"跳转详情页"]) return YES;
        if ([s containsString:@"点击查看详情"] && [s containsString:@"第三方"]) return YES;
        if ([s hasPrefix:@"跳过"] && s.length <= 8) {
            for (NSUInteger i = 2; i < s.length; i++) {
                unichar ch = [s characterAtIndex:i];
                if (ch >= '0' && ch <= '9') return YES;  // 「跳过 2」倒计时
            }
        }
    }
    return NO;
}

// v2 新增：页面运营位证据（只计浮标，不据此删主界面 cell，避免误伤）
static BOOL FCTextsAreOperationAd(NSArray<NSString *> *texts) {
    static NSArray *keys = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @[@"百元券包", @"限量7折", @"寄件省钱卡", @"查价领返现", @"换季洗羽绒", @"任选3件"];
    });
    for (NSString *s in texts) {
        for (NSString *k in keys) if ([s rangeOfString:k].location != NSNotFound) return YES;
    }
    return NO;
}

#pragma mark - 视图树文案收集

static void FCCollectText(UIView *v, NSMutableArray<NSString *> *out, int depth, int *budget) {
    if (!v || depth > 8 || out.count > 180 || *budget <= 0) return;
    *budget -= 1;
    if (v.hidden || v.alpha < 0.05) return;
    if (v.tag == 9527) return;  // 跳过诊断浮标

    NSString *s = nil;
    if ([v isKindOfClass:[UILabel class]])       s = ((UILabel *)v).text;
    else if ([v isKindOfClass:[UIButton class]]) s = ((UIButton *)v).currentTitle;
    else if ([v isKindOfClass:[UITextField class]]) s = ((UITextField *)v).text;
    if (s.length && s.length < 90) [out addObject:s];

    NSString *a = v.accessibilityLabel;
    if (a.length && a.length < 40) [out addObject:a];

    for (UIView *sub in v.subviews) FCCollectText(sub, out, depth + 1, budget);
}

static NSArray<NSString *> *FCTextsOf(UIView *root) {
    NSMutableArray *out = [NSMutableArray array];
    int budget = 360;
    FCCollectText(root, out, 0, &budget);
    return out;
}

#pragma mark - 关闭广告（公开 API，非 hook）

static NSMapTable<UIViewController *, NSNumber *> *gFCAttempts = nil;

static UIControl *FCFindCloseControl(UIView *root, CGFloat screenW) {
    if (!root) return nil;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    UIControl *topRight = nil;
    NSUInteger idx = 0;
    while (idx < queue.count && idx < 360) {
        UIView *v = queue[idx++];
        if (v.tag == 9527) continue;
        if ([v isKindOfClass:[UIControl class]]) {
            UIControl *c = (UIControl *)v;
            NSString *t = [c isKindOfClass:[UIButton class]] ? ((UIButton *)c).currentTitle : nil;
            NSString *both = [NSString stringWithFormat:@"%@ %@", t ?: @"", c.accessibilityLabel ?: @""];
            NSString *low = both.lowercaseString;
            if ([low containsString:@"关闭"] || [low containsString:@"跳过"] ||
                [low containsString:@"close"] || [low containsString:@"skip"] ||
                [both containsString:@"×"] || [both containsString:@"✕"]) return c;
            if (!topRight && c.enabled && !c.hidden) {
                CGRect r = [c convertRect:c.bounds toView:nil];
                if (r.origin.x > screenW - 150 && r.origin.y < 160 &&
                    r.size.width >= 12 && r.size.width <= 80 &&
                    r.size.height >= 12 && r.size.height <= 80) topRight = c;
            }
        }
        for (UIView *s in v.subviews) [queue addObject:s];
    }
    return topRight;
}

static void FCCloseAd(UIViewController *vc, UIWindow *w, BOOL isSplash) {
    CGFloat sw = [UIScreen mainScreen].bounds.size.width;
    UIView *root = vc.view ?: w;

    UIControl *c = FCFindCloseControl(root, sw);
    if (c && c.enabled && !c.hidden) {
        [c sendActionsForControlEvents:UIControlEventTouchUpInside];
        if (isSplash) gFCSplashHits++;
        FCLog(@"点了关闭按钮：%@（%@）", NSStringFromClass([vc class]), NSStringFromClass([c class]));
        return;
    }
    if (vc.presentingViewController) {
        [vc dismissViewControllerAnimated:NO completion:nil];
        if (isSplash) gFCSplashHits++;
        FCLog(@"dismiss：%@", NSStringFromClass([vc class]));
        return;
    }
    UIWindow *key = [UIApplication sharedApplication].keyWindow;
    if (w && w != key && ![NSStringFromClass([w class]) hasPrefix:@"UI"]) {
        w.userInteractionEnabled = NO;
        w.hidden = YES;
        if (isSplash) gFCSplashHits++;
        FCLog(@"隐藏独立广告 window：%@", NSStringFromClass([w class]));
        return;
    }
    UIView *mainView = w.rootViewController.view;
    for (UIView *s in [w.subviews copy]) {
        if (s == mainView || s.tag == 9527) continue;
        NSString *sc = NSStringFromClass([s class]);
        if (FCClassIsAd(sc) || FCTextsAreAd(FCTextsOf(s)) || FCTextsAreSplash(FCTextsOf(s))) {
            [s removeFromSuperview];
            if (isSplash) gFCSplashHits++;
            FCLog(@"移除 keyWindow 广告覆盖层：%@", sc);
        }
    }
}

#pragma mark - 窗口枚举与扫描

static NSArray<UIWindow *> *FCAllWindows(void) {
    NSMutableArray *a = [NSMutableArray array];
    UIApplication *app = [UIApplication sharedApplication];
    if ([app respondsToSelector:@selector(windows)]) {
        for (UIWindow *w in app.windows) if (![a containsObject:w]) [a addObject:w];
    }
    if (@available(iOS 13.0, *)) {
        for (UIScene *sc in app.connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                if (![a containsObject:w]) [a addObject:w];
            }
        }
    }
    return a;
}

static UIViewController *FCTopViewController(void) {
    UIWindow *key = [UIApplication sharedApplication].keyWindow;
    UIViewController *vc = key.rootViewController;
    int guard = 0;
    while (vc.presentedViewController && guard++ < 12) vc = vc.presentedViewController;
    return vc;
}

static void FCScanOnce(void) {
    NSArray<UIWindow *> *windows = FCAllWindows();
    gFCWindows = (NSUInteger)windows.count;
    for (UIWindow *w in windows) {
        if (!w || w.hidden || w.alpha < 0.01) continue;
        NSString *wc = NSStringFromClass([w class]);
        if ([wc hasPrefix:@"UITextEffects"] || [wc hasPrefix:@"UIRemoteKeyboard"] ||
            [wc hasPrefix:@"_UI"] || [wc isEqualToString:@"_UITouchEffectWindow"]) continue;

        NSArray<NSString *> *wtexts = FCTextsOf(w);
        BOOL opAd = FCTextsAreOperationAd(wtexts);
        if (opAd) gFCOpEvidence++;
        BOOL splash = FCTextsAreSplash(wtexts);

        UIViewController *vc = w.rootViewController;
        int guard = 0;
        while (vc && guard++ < 12) {
            NSString *cls = NSStringFromClass([vc class]);
            NSInteger tried = [[gFCAttempts objectForKey:vc] integerValue];
            if (!FCIsExcludedClass(cls) && tried < 4) {
                NSArray<NSString *> *vtexts = FCTextsOf(vc.view);
                BOOL splashVC = FCTextsAreSplash(vtexts);
                BOOL ad = FCClassIsAd(cls) || FCTextsAreAd(vtexts) || splashVC || splash;
                if (ad) {
                    gFCEvidences++;
                    [gFCAttempts setObject:@(tried + 1) forKey:vc];
                    FCCloseAd(vc, w, splash || splashVC);
                    break;
                }
            }
            vc = vc.presentedViewController;
        }

        if (w.subviews.count > 1) {
            UIView *mainView = w.rootViewController.view;
            for (UIView *s in [w.subviews copy]) {
                if (s == mainView || s.tag == 9527) continue;
                NSString *sc = NSStringFromClass([s class]);
                NSArray<NSString *> *st = FCTextsOf(s);
                if (FCClassIsAd(sc) || FCTextsAreAd(st) || FCTextsAreSplash(st)) {
                    [s removeFromSuperview];
                    if (FCTextsAreSplash(st)) gFCSplashHits++;
                    FCLog(@"移除广告覆盖层：%@", sc);
                }
            }
        }
    }
}

#pragma mark - WKWebView H5 运营位注入（公开 API，非 hook）

static void FCInjectWebViews(void) {
    Class wk = NSClassFromString(@"WKWebView");
    if (!wk) return;
    SEL sel = NSSelectorFromString(@"evaluateJavaScript:completionHandler:");
    NSDate *now = [NSDate date];
    static char kKey;
    gFCWebViewFound = 0;

    for (UIWindow *w in FCAllWindows()) {
        NSMutableArray<UIView *> *q = [NSMutableArray arrayWithObject:w];
        NSUInteger idx = 0;
        while (idx < q.count && idx < 500) {
            UIView *v = q[idx++];
            if ([v isKindOfClass:wk]) {
                gFCWebViewFound++;
                NSDate *last = objc_getAssociatedObject(v, &kKey);
                if (!last || [now timeIntervalSinceDate:last] > 1.5) {
                    objc_setAssociatedObject(v, &kKey, now, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    if ([v respondsToSelector:sel]) {
                        IMP imp = [v methodForSelector:sel];
                        if (imp) {
                            void (^cb)(id, NSError *) = ^(id result, NSError *err){
                                if (!err && result) {
                                    NSInteger h = [NSString stringWithFormat:@"%@", result].integerValue;
                                    if (h > (NSInteger)gFCH5Hits) gFCH5Hits = (NSUInteger)h;
                                }
                            };
                            ((void (*)(id, SEL, NSString *, void (^)(id, NSError *)))imp)(v, sel, FCJSAdCards, cb);
                        }
                    }
                }
            }
            for (UIView *sub in v.subviews) [q addObject:sub];
        }
    }
}

#pragma mark - 诊断浮标

#ifdef FC_SHOW_BADGE
static void FCUpdateBadge(void) {
    UIWindow *key = [UIApplication sharedApplication].keyWindow;
    if (!key) return;
    UILabel *b = (UILabel *)[key viewWithTag:9527];
    if (!b) {
        b = [[UILabel alloc] initWithFrame:CGRectMake(0, 22, [UIScreen mainScreen].bounds.size.width, 18)];
        b.tag = 9527;
        b.font = [UIFont systemFontOfSize:9];
        b.textColor = [UIColor whiteColor];
        b.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.5];
        b.textAlignment = NSTextAlignmentCenter;
        b.userInteractionEnabled = NO;
        b.adjustsFontSizeToFitWidth = YES;
        [key addSubview:b];
    }
    NSString *top = NSStringFromClass([FCTopViewController() class]) ?: @"-";
    b.text = [NSString stringWithFormat:@"FCv2 窗%lu/证%lu/屏%lu/运%lu Web%lu H5%lu | %@",
              (unsigned long)gFCWindows, (unsigned long)gFCEvidences, (unsigned long)gFCSplashHits,
              (unsigned long)gFCOpEvidence, (unsigned long)gFCWebViewFound,
              (unsigned long)gFCH5Hits, top];
}
#endif

#pragma mark - B 档：源头拦截宿主自有广告类（不碰系统类）

#ifdef FC_DEEP_HOOKS
static id FCVoidStub(id self, SEL _cmd) { return nil; }

static void FCSwizzleOwnMethods(NSString *clsName, NSArray<NSString *> *sels) {
    Class c = FCResolveClass(clsName);
    if (!c) return;
    for (NSString *selName in sels) {
        SEL s = NSSelectorFromString(selName);
        unsigned int n = 0;
        Method *list = class_copyMethodList(c, &n);
        for (unsigned int i = 0; i < n; i++) {
            if (method_getName(list[i]) == s) {
                method_setImplementation(list[i], (IMP)FCVoidStub);
                FCLog(@"源头拦截 -[%@ %@]", clsName, selName);
                break;
            }
        }
        free(list);
    }
}

static void FCInstallDeepHooks(void) {
    NSArray<NSArray *> *table = @[
        @[@"FCSplashADSManager", @[@"show", @"start", @"requestSplashAd", @"loadSplashAd", @"showSplashAd"]],
        @[@"SplashAdManager",    @[@"show", @"start", @"load", @"requestAd", @"showSplash"]],
        @[@"SplashAdLibHandler", @[@"load", @"show", @"requestAd"]],
        @[@"CheckOutAlertInsertADViewController", @[@"viewDidLoad", @"show", @"loadAd"]],
        @[@"InterstScrAdLibTaku", @[@"show", @"load", @"requestAd"]],
        @[@"InterstScrAdLibUBIX", @[@"show", @"load", @"requestAd"]],
        @[@"OpenScrAdLibToBid",   @[@"show", @"load", @"requestAd"]],
        @[@"OpenScrAdLibUBIX",    @[@"show", @"load", @"requestAd"]],
    ];
    for (NSArray *row in table) FCSwizzleOwnMethods(row[0], row[1]);
}
#endif

#pragma mark - 入口

__attribute__((constructor))
static void FCAdBlockInit(void) {
    @autoreleasepool {
        FCLog(@"v2 载入，Bundle=%@", [[NSBundle mainBundle] bundleIdentifier]);
        gFCAttempts = [NSMapTable weakToStrongObjectsMapTable];

        dispatch_async(dispatch_get_main_queue(), ^{
            __block NSInteger fastTicks = 0;
            NSTimer *fast = [NSTimer scheduledTimerWithTimeInterval:0.10 repeats:YES
                              block:^(NSTimer *t) {
                FCScanOnce();
                if (++fastTicks > 80) [t invalidate];
            }];
            [[NSRunLoop mainRunLoop] addTimer:fast forMode:NSRunLoopCommonModes];

            __block NSInteger slowTicks = 0;
            NSTimer *slow = [NSTimer scheduledTimerWithTimeInterval:0.30 repeats:YES
                              block:^(NSTimer *t) {
                FCScanOnce();
                // 每 5 次（约 1.5s）重新注入一次 H5 脚本，覆盖页面跳转后的新 document
                if (++slowTicks % 5 == 0) FCInjectWebViews();
#ifdef FC_SHOW_BADGE
                FCUpdateBadge();
#endif
            }];
            [[NSRunLoop mainRunLoop] addTimer:slow forMode:NSRunLoopCommonModes];

#ifdef FC_DEEP_HOOKS
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ FCInstallDeepHooks(); });
#endif
        });
    }
}

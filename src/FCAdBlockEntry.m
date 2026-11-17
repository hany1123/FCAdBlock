//
//  FCAdBlockEntry.m —— 丰巢 (HiveConsumer) 去广告插件
//
//  静态分析依据（丰巢 6.48.1 主二进制，122MB，arm64）：
//    宿主 = uni-app + AWM/WindMill 聚合广告中台
//      (ABU/穿山甲GroMore + GDT广点通 + KS快手 + 百度 + QuMeng趣盟 + Sigmob 多 adn)
//    宿主自有广告类（Swift，_TtC12HiveConsumer*，已在 __objc_classname 验证）：
//      开屏: FCSplashADSManager / SplashAdManager / SplashAdLibHandler /
//            NativeSplashAdView / SplashAdBottomView / SplashAdModel
//      插屏: CheckOutAlertInsertADViewController / InterstScrAdLibTaku /
//            InterstScrAdLibUBIX / OpenScrAdLibToBid / OpenScrAdLibUBIX
//      弹窗: LifeServiceHomeADPopAlertView / DSPHomeAdsAlertView
//      Banner/信息流: SendOrderAdBannerView / BoxMobilePickADBannerView /
//            CheckoutAdFeedBannerCell / CheckoutAdFeedMixBannerCell /
//            CheckoutAdFeedSepBannerCell / WashSOAdsView / WashSOAdsSectionView
//
//  硬约束（严格遵守）：
//    1. 不 hook 任何系统类方法（UIApplication/UIViewController/UIView 等）
//    2. 不用 Logos / CydiaSubstrate，入口为纯 .m + constructor 构造函数
//    3. B 档只 swizzle 宿主自有广告类（class_copyMethodList 限定类自身方法）
//    4. A 档零 hook：只做定时视图扫描 + 调用公开 API 关闭
//    5. 类名判定排除 "Adress/Address"（地址业务，丰巢核心功能）
//
//  说明：Swift 类的 selector 由 @objc 暴露时，NSClassFromString("HiveConsumer.Xxx")
//        与 NSClassFromString("Xxx") 均可能命中，两种都尝试。
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#define FCLog(fmt, ...) NSLog((@"[FCAdBlock] " fmt), ##__VA_ARGS__)

#pragma mark - 类名判定

// 宿主自有广告类「强特征」白名单。
// 只收广告专属类，绝不写泛化的 Vip / Member / Pay，避免误伤会员页。
// 注意：不含任何 "Adress/Address" 地址类。
static NSArray<NSString *> *FCAdClassKeys(void) {
    static NSArray *keys = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @[
            // 开屏
            @"FCSplashADSManager", @"SplashAdManager", @"SplashAdLibHandler",
            @"NativeSplashAdView", @"SplashAdBottomView", @"SplashAdScreenShotManager",
            // 插屏 / 全屏
            @"CheckOutAlertInsertADViewController", @"InterstScrAdLibTaku",
            @"InterstScrAdLibUBIX", @"OpenScrAdLibToBid", @"OpenScrAdLibUBIX",
            // 广告弹窗
            @"LifeServiceHomeADPopAlertView", @"DSPHomeAdsAlertView",
            // Banner / 信息流广告位
            @"SendOrderAdBannerView", @"BoxMobilePickADBannerView",
            @"BoxMobilePickADBannerLeftView", @"BoxMobilePickADBannerTopView",
            @"BoxMobilePickADBannerSuccessView",
            @"CheckoutAdFeedBannerCell", @"CheckoutAdFeedMixBannerCell",
            @"CheckoutAdFeedSepBannerCell", @"WashSOAdsView", @"WashSOAdsSectionView",
            @"LifeServiceDetailAdCell", @"WashImportSendAdsCell",
            @"CashDeskTakuADCell",
            // 广告中台管理类
            @"AdCenter", @"AdsHandle", @"AdsCNManager",
        ];
    });
    return keys;
}

// 明确排除：地址业务（Adress/Address）与系统类
static BOOL FCIsExcludedClass(NSString *cls) {
    if ([cls rangeOfString:@"Adress" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    if ([cls rangeOfString:@"Address" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    if ([cls hasPrefix:@"_UI"] || [cls hasPrefix:@"UI"] || [cls hasPrefix:@"NS"] ||
        [cls isEqualToString:@"UIAlertController"] ||
        [cls isEqualToString:@"UIActivityViewController"] ||
        [cls hasPrefix:@"SFSafari"] || [cls hasPrefix:@"MFMail"] ||
        [cls hasPrefix:@"QLPreview"]) return YES;
    return NO;
}

static BOOL FCClassIsAd(NSString *cls) {
    if (!cls.length || FCIsExcludedClass(cls)) return NO;
    for (NSString *k in FCAdClassKeys()) {
        if ([cls rangeOfString:k options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    return NO;
}

// NSClassFromString 对 Swift 类的两种命名都尝试
static Class FCResolveClass(NSString *name) {
    Class c = NSClassFromString(name);
    if (c) return c;
    c = NSClassFromString([@"HiveConsumer." stringByAppendingString:name]);
    return c;
}

#pragma mark - 文案判定（window 级证据）

static BOOL FCTextsAreAd(NSArray<NSString *> *texts) {
    BOOL hasAdTag = NO, hasAction = NO;
    for (NSString *raw in texts) {
        NSString *s = [raw stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (s.length == 0) continue;

        // 激励/开屏广告独有文案：命中一条即可
        if ([s containsString:@"秒后可领奖励"] ||
            [s containsString:@"后可领奖励"] ||
            [s containsString:@"跳过广告"] ||
            [s containsString:@"看广告"] ||
            [s containsString:@"观看广告"] ||
            [s containsString:@"看视频"] ||
            [s containsString:@"免广告"] ||
            [s containsString:@"继续观看"] ||
            [s containsString:@"可获得奖励"] ||
            ([s containsString:@"再看"] && [s containsString:@"广告"])) {
            return YES;
        }
        if ([s isEqualToString:@"广告"] || [s isEqualToString:@"广告 |"] ||
            [s isEqualToString:@"广告｜"] ||
            ([s hasPrefix:@"广告"] && s.length <= 5)) hasAdTag = YES;
        if ([s containsString:@"立即购买"] || [s containsString:@"立即开通"] ||
            [s containsString:@"跳过"] || [s containsString:@"领奖励"] ||
            [s containsString:@"去领奖"] || [s containsString:@"领取奖励"] ||
            [s containsString:@"立即领取"]) hasAction = YES;
    }
    return hasAdTag && hasAction;
}

#pragma mark - 视图树文案收集

static void FCCollectText(UIView *v, NSMutableArray<NSString *> *out, int depth, int *budget) {
    if (!v || depth > 8 || out.count > 180 || *budget <= 0) return;
    *budget -= 1;
    if (v.hidden || v.alpha < 0.05) return;

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

#pragma mark - 关闭广告

static NSMapTable<UIViewController *, NSNumber *> *gFCAttempts = nil;

static UIControl *FCFindCloseControl(UIView *root, CGFloat screenW) {
    if (!root) return nil;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    UIControl *topRight = nil;
    NSUInteger idx = 0;
    while (idx < queue.count && idx < 360) {
        UIView *v = queue[idx++];
        if ([v isKindOfClass:[UIControl class]]) {
            UIControl *c = (UIControl *)v;
            NSString *t = [c isKindOfClass:[UIButton class]] ? ((UIButton *)c).currentTitle : nil;
            NSString *both = [NSString stringWithFormat:@"%@ %@", t ?: @"", c.accessibilityLabel ?: @""];
            NSString *low = both.lowercaseString;
            if ([low containsString:@"关闭"] || [low containsString:@"跳过"] ||
                [low containsString:@"close"] || [low containsString:@"skip"] ||
                [both containsString:@"×"] || [both containsString:@"✕"]) {
                return c;
            }
            if (!topRight && c.enabled && !c.hidden) {
                CGRect r = [c convertRect:c.bounds toView:nil];
                if (r.origin.x > screenW - 150 && r.origin.y < 160 &&
                    r.size.width >= 12 && r.size.width <= 80 &&
                    r.size.height >= 12 && r.size.height <= 80) {
                    topRight = c;
                }
            }
        }
        for (UIView *s in v.subviews) [queue addObject:s];
    }
    return topRight;
}

static void FCCloseAd(UIViewController *vc, UIWindow *w) {
    CGFloat sw = [UIScreen mainScreen].bounds.size.width;
    UIView *root = vc.view ?: w;

    UIControl *c = FCFindCloseControl(root, sw);
    if (c && c.enabled && !c.hidden) {
        [c sendActionsForControlEvents:UIControlEventTouchUpInside];
        FCLog(@"点了关闭按钮：%@（%@）", NSStringFromClass([vc class]), NSStringFromClass([c class]));
        return;
    }
    if (vc.presentingViewController) {
        [vc dismissViewControllerAnimated:NO completion:nil];
        FCLog(@"dismiss：%@", NSStringFromClass([vc class]));
        return;
    }
    UIWindow *key = [UIApplication sharedApplication].keyWindow;
    if (w && w != key && ![NSStringFromClass([w class]) hasPrefix:@"UI"]) {
        w.userInteractionEnabled = NO;
        w.hidden = YES;
        FCLog(@"隐藏独立广告 window：%@", NSStringFromClass([w class]));
        return;
    }
    UIView *mainView = w.rootViewController.view;
    for (UIView *s in [w.subviews copy]) {
        if (s == mainView) continue;
        NSString *sc = NSStringFromClass([s class]);
        if (FCClassIsAd(sc) || FCTextsAreAd(FCTextsOf(s))) {
            [s removeFromSuperview];
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

static void FCScanOnce(void) {
    for (UIWindow *w in FCAllWindows()) {
        if (!w || w.hidden || w.alpha < 0.01) continue;
        NSString *wc = NSStringFromClass([w class]);
        if ([wc hasPrefix:@"UITextEffects"] || [wc hasPrefix:@"UIRemoteKeyboard"] ||
            [wc hasPrefix:@"_UI"] || [wc isEqualToString:@"_UITouchEffectWindow"]) continue;

        UIViewController *vc = w.rootViewController;
        int guard = 0;
        while (vc && guard++ < 12) {
            NSString *cls = NSStringFromClass([vc class]);
            NSInteger tried = [[gFCAttempts objectForKey:vc] integerValue];
            if (!FCIsExcludedClass(cls) && tried < 4) {
                BOOL ad = FCClassIsAd(cls) || FCTextsAreAd(FCTextsOf(vc.view));
                if (ad) {
                    [gFCAttempts setObject:@(tried + 1) forKey:vc];
                    FCCloseAd(vc, w);
                    break;
                }
            }
            vc = vc.presentedViewController;
        }

        // 广告作为 view 直接盖在 window 上
        if (w.subviews.count > 1) {
            UIView *mainView = w.rootViewController.view;
            for (UIView *s in [w.subviews copy]) {
                if (s == mainView) continue;
                NSString *sc = NSStringFromClass([s class]);
                if (FCClassIsAd(sc) || FCTextsAreAd(FCTextsOf(s))) {
                    [s removeFromSuperview];
                    FCLog(@"移除广告覆盖层：%@", sc);
                }
            }
        }
    }
}

#pragma mark - B 档：源头拦截宿主自有广告类（不碰系统类）

#ifdef FC_DEEP_HOOKS
static id FCVoidStub(id self, SEL _cmd) { return nil; }

// 只改「该类自己实现」的方法（class_copyMethodList），绝不沿继承链碰系统类
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
    // 只拦截宿主自有广告类的展示/加载入口；不碰任何 UIKit / 系统类。
    // selector 来自宿主方法表与广告语义，运行时用 class_copyMethodList 精确匹配，
    // 匹配不到就跳过（Swift 类 selector 名称可能有变化，安全降级）。
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
        FCLog(@"载入，Bundle=%@", [[NSBundle mainBundle] bundleIdentifier]);
        gFCAttempts = [NSMapTable weakToStrongObjectsMapTable];

        dispatch_async(dispatch_get_main_queue(), ^{
            // 冷启动前 8 秒加密扫描，专门抓开屏广告；之后降到 0.3s
            __block NSInteger fastTicks = 0;
            NSTimer *fast = [NSTimer scheduledTimerWithTimeInterval:0.10 repeats:YES
                              block:^(NSTimer *t) {
                FCScanOnce();
                if (++fastTicks > 80) [t invalidate];
            }];
            [[NSRunLoop mainRunLoop] addTimer:fast forMode:NSRunLoopCommonModes];

            NSTimer *slow = [NSTimer scheduledTimerWithTimeInterval:0.30 repeats:YES
                              block:^(NSTimer *t) { FCScanOnce(); }];
            [[NSRunLoop mainRunLoop] addTimer:slow forMode:NSRunLoopCommonModes];

#ifdef FC_DEEP_HOOKS
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ FCInstallDeepHooks(); });
#endif
        });
    }
}

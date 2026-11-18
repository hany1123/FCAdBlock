//
//  FCAdBlockEntry.m —— 丰巢 (HiveConsumer) 去广告插件 v3
//
//  v3 相对 v2（真机二次反馈）：
//    * 浮标只闪一下就没了 → v2 把浮标加在 keyWindow，被页面切换覆盖。
//      v3 改为独立 UIWindow（设 windowScene、canBecomeKeyWindow=NO、
//      windowLevel=alert-1、pointInside 只按子视图命中、自实现 hitTest），常驻不吞触摸。
//    * 新增「点选模式」：点浮标 → 浮标窗口这一次全屏吞触摸拿坐标 (x,y) →
//      找屏幕上的 WKWebView → 注入 JS document.elementFromPoint(x,y) 命中 DOM →
//      向上收容器 + display:none + 读元素文字特征 → 回传 ObjC 存 NSUserDefaults →
//      以后每次注入把用户规则 concat 进关键词，自动隐藏同类元素。
//
//  取证结论（沿用 v2）：页面运营位文案在全 IPA 1208 文件零命中 = 服务端 DSP 下发 H5，
//  渲染在 WKWebView；开屏只有「跳过 2」无广告角标，需单词强特征。
//
//  硬约束：不 hook 系统类方法（自定义 UIWindow 子类重写 hitTest 不属于 hook）；
//  纯 .m 无 Logos；B 档只改宿主自有类；A 档零 hook；排除 Adress/Address。
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#define FCLog(fmt, ...) NSLog((@"[FCAdBlock] " fmt), ##__VA_ARGS__)

#pragma mark - 前置声明

static void FCUpdateBadge(void);
static void FCShowBadgeMsg(NSString *msg);
static NSArray<NSString *> *FCUserRules(void);
static NSString *FCJSSafe(NSString *s);
static NSString *FCBuildInjectionJS(void);

#pragma mark - H5 脚本模板

// 用户规则以 JS 数组字面量插入到 %@；脚本内其余全用单引号、零反斜杠。
// __fcadUserRules 每次注入都刷新，sweep 从它读最新规则（同 document 幂等但规则可更新）。
static NSString * const FCJSAdCardsTemplate =
@"(function(){var W=window;W.__fcadUserRules=%@;"
"if(W.__fcadLoaded){if(W.__fcadSweep){W.__fcadSweep();}return;}"
"W.__fcadLoaded=1;W.__fcadHits=0;"
"var K=['百元券包','限量7折','寄件省钱卡','查价领返现','换季洗羽绒','任选3件'];"
"function hit(t){if(!t||t.length>160){return false;}"
"var A=K.concat(W.__fcadUserRules||[]);"
"for(var i=0;i<A.length;i++){if(t.indexOf(A[i])>=0){return true;}}return false;}"
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

// 点选拾取脚本（纯 ASCII，%f 两个）：屏幕坐标 → webview 内坐标后注入
static NSString * const FCPickJSFmt =
@"(function(){var e=document.elementFromPoint(%f,%f);if(!e){return 'MISS';}"
"var t=e;for(var k=0;k<3;k++){var p=t.parentElement;if(!p||p===document.body){break;}"
"var pr=p.getBoundingClientRect();var tr=t.getBoundingClientRect();"
"if(tr.height>0&&pr.height<=tr.height*1.8&&pr.width<=window.innerWidth*0.97){t=p;}else{break;}}"
"var r=t.getBoundingClientRect();if(r.height>window.innerHeight*0.7){return 'TOOBIG';}"
"t.style.setProperty('display','none','important');t.__fcadDone=1;"
"var txt=(t.innerText||t.textContent||'');return txt.substring(0,40);})();";

#pragma mark - 用户规则持久化

static NSString * const FCUserRulesKey = @"FCAdBlockUserRules_v3";

static NSArray<NSString *> *FCUserRules(void) {
    NSArray *a = [[NSUserDefaults standardUserDefaults] arrayForKey:FCUserRulesKey];
    return a ?: @[];
}

static NSString *FCJSSafe(NSString *s) {
    s = [s stringByReplacingOccurrencesOfString:@"'" withString:@""];
    s = [s stringByReplacingOccurrencesOfString:@"\\" withString:@""];
    s = [s stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    s = [s stringByReplacingOccurrencesOfString:@"\r" withString:@" "];
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (s.length > 30) s = [s substringToIndex:30];
    return s;
}

static void FCAddUserRule(NSString *raw) {
    NSString *rule = FCJSSafe(raw);
    if (rule.length < 2) return;
    NSMutableArray *a = [NSMutableArray arrayWithArray:FCUserRules()];
    for (NSString *exist in a) {
        if ([exist rangeOfString:rule].location != NSNotFound ||
            [rule rangeOfString:exist].location != NSNotFound) return;  // 去重（含子串）
    }
    [a addObject:rule];
    if (a.count > 40) [a removeObjectsInRange:NSMakeRange(0, a.count - 40)];
    [[NSUserDefaults standardUserDefaults] setObject:a forKey:FCUserRulesKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    FCLog(@"记录用户规则：%@", rule);
}

static NSString *FCBuildInjectionJS(void) {
    NSArray *rules = FCUserRules();
    NSMutableString *rjs = [NSMutableString stringWithString:@"["];
    for (NSString *s in rules) [rjs appendFormat:@"'%@',", FCJSSafe(s)];
    [rjs appendString:@"]"];
    return [NSString stringWithFormat:FCJSAdCardsTemplate, rjs];
}

#pragma mark - 运行计数

static NSUInteger gFCWindows = 0, gFCEvidences = 0, gFCSplashHits = 0;
static NSUInteger gFCOpEvidence = 0, gFCWebViewFound = 0, gFCH5Hits = 0;

#pragma mark - 类名 / 文案判定

static NSArray<NSString *> *FCAdClassKeys(void) {
    static NSArray *keys = nil; static dispatch_once_t once;
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
            @"LifeServiceDetailAdCell", @"WashImportSendAdsCell", @"CashDeskTakuADCell",
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
    for (NSString *k in FCAdClassKeys())
        if ([cls rangeOfString:k options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
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
    return c ?: NSClassFromString([@"HiveConsumer." stringByAppendingString:name]);
}

static BOOL FCTextsAreAd(NSArray<NSString *> *texts) {
    BOOL hasAdTag = NO, hasAction = NO;
    for (NSString *raw in texts) {
        NSString *s = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!s.length) continue;
        if ([s containsString:@"秒后可领奖励"] || [s containsString:@"后可领奖励"] ||
            [s containsString:@"跳过广告"] || [s containsString:@"看广告"] ||
            [s containsString:@"观看广告"] || [s containsString:@"看视频"] ||
            [s containsString:@"免广告"] || [s containsString:@"继续观看"] ||
            [s containsString:@"可获得奖励"] ||
            ([s containsString:@"再看"] && [s containsString:@"广告"])) return YES;
        if ([s isEqualToString:@"广告"] || [s isEqualToString:@"广告 |"] ||
            [s isEqualToString:@"广告｜"] || ([s hasPrefix:@"广告"] && s.length <= 5)) hasAdTag = YES;
        if ([s containsString:@"立即购买"] || [s containsString:@"跳过"] ||
            [s containsString:@"领奖励"] || [s containsString:@"去领奖"] ||
            [s containsString:@"领取奖励"] || [s containsString:@"立即领取"]) hasAction = YES;
    }
    return hasAdTag && hasAction;
}

static BOOL FCTextsAreSplash(NSArray<NSString *> *texts) {
    for (NSString *raw in texts) {
        NSString *s = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([s containsString:@"摇动或点击"]) return YES;
        if ([s containsString:@"跳转详情页"]) return YES;
        if ([s containsString:@"点击查看详情"] && [s containsString:@"第三方"]) return YES;
        if ([s hasPrefix:@"跳过"] && s.length <= 8)
            for (NSUInteger i = 2; i < s.length; i++) {
                unichar ch = [s characterAtIndex:i];
                if (ch >= '0' && ch <= '9') return YES;
            }
    }
    return NO;
}

static BOOL FCTextsAreOperationAd(NSArray<NSString *> *texts) {
    static NSArray *keys = nil; static dispatch_once_t once;
    dispatch_once(&once, ^{ keys = @[@"百元券包",@"限量7折",@"寄件省钱卡",@"查价领返现",@"换季洗羽绒",@"任选3件"]; });
    for (NSString *s in texts) for (NSString *k in keys)
        if ([s rangeOfString:k].location != NSNotFound) return YES;
    return NO;
}

#pragma mark - 视图树

static void FCCollectText(UIView *v, NSMutableArray<NSString *> *out, int depth, int *budget) {
    if (!v || depth > 8 || out.count > 180 || *budget <= 0) return;
    *budget -= 1;
    if (v.hidden || v.alpha < 0.05 || v.tag == 9527) return;
    NSString *s = nil;
    if ([v isKindOfClass:[UILabel class]]) s = ((UILabel *)v).text;
    else if ([v isKindOfClass:[UIButton class]]) s = ((UIButton *)v).currentTitle;
    else if ([v isKindOfClass:[UITextField class]]) s = ((UITextField *)v).text;
    if (s.length && s.length < 90) [out addObject:s];
    NSString *a = v.accessibilityLabel;
    if (a.length && a.length < 40) [out addObject:a];
    for (UIView *sub in v.subviews) FCCollectText(sub, out, depth + 1, budget);
}

static NSArray<NSString *> *FCTextsOf(UIView *root) {
    NSMutableArray *out = [NSMutableArray array]; int budget = 360;
    FCCollectText(root, out, 0, &budget);
    return out;
}

static NSMapTable<UIViewController *, NSNumber *> *gFCAttempts = nil;

static UIControl *FCFindCloseControl(UIView *root, CGFloat screenW) {
    if (!root) return nil;
    NSMutableArray *queue = [NSMutableArray arrayWithObject:root];
    UIControl *topRight = nil; NSUInteger idx = 0;
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
        return;
    }
    if (vc.presentingViewController) {
        [vc dismissViewControllerAnimated:NO completion:nil];
        if (isSplash) gFCSplashHits++;
        return;
    }
    UIWindow *key = [UIApplication sharedApplication].keyWindow;
    if (w && w != key && ![NSStringFromClass([w class]) hasPrefix:@"UI"]) {
        w.userInteractionEnabled = NO; w.hidden = YES;
        if (isSplash) gFCSplashHits++;
        return;
    }
    UIView *mainView = w.rootViewController.view;
    for (UIView *s in [w.subviews copy]) {
        if (s == mainView || s.tag == 9527) continue;
        NSString *sc = NSStringFromClass([s class]); NSArray *st = FCTextsOf(s);
        if (FCClassIsAd(sc) || FCTextsAreAd(st) || FCTextsAreSplash(st)) {
            [s removeFromSuperview]; if (isSplash) gFCSplashHits++;
        }
    }
}

static NSArray<UIWindow *> *FCAllWindows(void) {
    NSMutableArray *a = [NSMutableArray array];
    UIApplication *app = [UIApplication sharedApplication];
    if ([app respondsToSelector:@selector(windows)])
        for (UIWindow *w in app.windows) if (![a containsObject:w]) [a addObject:w];
    if (@available(iOS 13.0, *))
        for (UIScene *sc in app.connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)sc).windows)
                if (![a containsObject:w]) [a addObject:w];
        }
    return a;
}

static UIViewController *FCTopViewController(void) {
    UIWindow *key = [UIApplication sharedApplication].keyWindow;
    UIViewController *vc = key.rootViewController; int guard = 0;
    while (vc.presentedViewController && guard++ < 12) vc = vc.presentedViewController;
    return vc;
}

static void FCScanOnce(void) {
    NSArray *windows = FCAllWindows(); gFCWindows = windows.count;
    for (UIWindow *w in windows) {
        if (!w || w.hidden || w.alpha < 0.01) continue;
        NSString *wc = NSStringFromClass([w class]);
        if ([wc isEqualToString:@"FCBadgeWindow"]) continue;  // 跳过自己
        if ([wc hasPrefix:@"UITextEffects"] || [wc hasPrefix:@"UIRemoteKeyboard"] ||
            [wc hasPrefix:@"_UI"] || [wc isEqualToString:@"_UITouchEffectWindow"]) continue;
        NSArray *wtexts = FCTextsOf(w);
        if (FCTextsAreOperationAd(wtexts)) gFCOpEvidence++;
        BOOL splash = FCTextsAreSplash(wtexts);
        UIViewController *vc = w.rootViewController; int guard = 0;
        while (vc && guard++ < 12) {
            NSString *cls = NSStringFromClass([vc class]);
            NSInteger tried = [[gFCAttempts objectForKey:vc] integerValue];
            if (!FCIsExcludedClass(cls) && tried < 4) {
                NSArray *vtexts = FCTextsOf(vc.view);
                BOOL splashVC = FCTextsAreSplash(vtexts);
                if (FCClassIsAd(cls) || FCTextsAreAd(vtexts) || splashVC || splash) {
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
                NSString *sc = NSStringFromClass([s class]); NSArray *st = FCTextsOf(s);
                if (FCClassIsAd(sc) || FCTextsAreAd(st) || FCTextsAreSplash(st)) {
                    [s removeFromSuperview]; if (FCTextsAreSplash(st)) gFCSplashHits++;
                }
            }
        }
    }
}

#pragma mark - WKWebView 注入 / 点选拾取

static void FCInjectWebViewsForce(BOOL force) {
    Class wk = NSClassFromString(@"WKWebView"); if (!wk) return;
    SEL sel = NSSelectorFromString(@"evaluateJavaScript:completionHandler:");
    NSDate *now = [NSDate date]; static char kKey;
    gFCWebViewFound = 0;
    NSString *js = FCBuildInjectionJS();
    for (UIWindow *w in FCAllWindows()) {
        if ([NSStringFromClass([w class]) isEqualToString:@"FCBadgeWindow"]) continue;
        NSMutableArray *q = [NSMutableArray arrayWithObject:w]; NSUInteger idx = 0;
        while (idx < q.count && idx < 500) {
            UIView *v = q[idx++];
            if ([v isKindOfClass:wk]) {
                gFCWebViewFound++;
                NSDate *last = objc_getAssociatedObject(v, &kKey);
                if (force || !last || [now timeIntervalSinceDate:last] > 1.5) {
                    objc_setAssociatedObject(v, &kKey, now, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    if ([v respondsToSelector:sel]) {
                        IMP imp = [v methodForSelector:sel];
                        if (imp) ((void (*)(id, SEL, NSString *, void (^)(id, NSError *)))imp)
                            (v, sel, js, ^(id result, NSError *err){
                                if (!err && result) {
                                    NSInteger h = [NSString stringWithFormat:@"%@", result].integerValue;
                                    if (h > (NSInteger)gFCH5Hits) gFCH5Hits = (NSUInteger)h;
                                }
                            });
                    }
                }
            }
            for (UIView *sub in v.subviews) [q addObject:sub];
        }
    }
}

// 屏幕坐标点选：找命中的最小 WKWebView，注入拾取脚本，隐藏元素并记录特征
static void FCPickAtPoint(CGPoint screenP) {
    Class wk = NSClassFromString(@"WKWebView"); if (!wk) { FCShowBadgeMsg(@"无网页组件"); return; }
    SEL sel = NSSelectorFromString(@"evaluateJavaScript:completionHandler:");
    UIView *best = nil; CGPoint bestP = CGPointZero; CGFloat bestArea = CGFLOAT_MAX;
    for (UIWindow *w in FCAllWindows()) {
        if ([NSStringFromClass([w class]) isEqualToString:@"FCBadgeWindow"]) continue;
        NSMutableArray *q = [NSMutableArray arrayWithObject:w]; NSUInteger idx = 0;
        while (idx < q.count && idx < 600) {
            UIView *v = q[idx++];
            if ([v isKindOfClass:wk] && !v.hidden && v.alpha > 0.01) {
                CGPoint lp = [v convertPoint:screenP fromView:nil];
                if (CGRectContainsPoint(v.bounds, lp)) {
                    CGFloat area = v.bounds.size.width * v.bounds.size.height;
                    if (area < bestArea) { bestArea = area; best = v; bestP = lp; }
                }
            }
            for (UIView *s in v.subviews) [q addObject:s];
        }
    }
    if (!best) { FCShowBadgeMsg(@"非网页元素"); return; }
    NSString *js = [NSString stringWithFormat:FCPickJSFmt, bestP.x, bestP.y];
    if (![best respondsToSelector:sel]) { FCShowBadgeMsg(@"注入不可用"); return; }
    IMP imp = [best methodForSelector:sel]; if (!imp) { FCShowBadgeMsg(@"注入不可用"); return; }
    ((void (*)(id, SEL, NSString *, void (^)(id, NSError *)))imp)
        (best, sel, js, ^(id result, NSError *err){
            NSString *msg = @"未命中元素";
            if (!err && [result isKindOfClass:[NSString class]]) {
                NSString *txt = (NSString *)result;
                if (txt.length >= 2 && ![txt hasPrefix:@"MISS"] && ![txt hasPrefix:@"TOOBIG"]) {
                    FCAddUserRule(txt);
                    msg = @"已隐藏并记住";
                } else if ([txt hasPrefix:@"TOOBIG"]) msg = @"元素过大未取";
            }
            NSString *m = msg;
            dispatch_async(dispatch_get_main_queue(), ^{
                FCInjectWebViewsForce(YES);   // 立刻用新规则重新注入
                FCShowBadgeMsg(m);
            });
        });
}

#pragma mark - 常驻浮标窗口（独立 window，不抢 keyWindow，穿透触摸）

@interface FCBadgeWindow : UIWindow
@property (nonatomic, assign) BOOL picking;
@end

static UIButton *gFCBadgeBtn = nil;
static FCBadgeWindow *gFCBadgeWindow = nil;

@implementation FCBadgeWindow

- (BOOL)canBecomeKeyWindow { return NO; }

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.picking) return YES;                 // 点选模式：全屏接住这一次触摸
    for (UIView *v in self.subviews)
        if (!v.hidden && v.userInteractionEnabled && CGRectContainsPoint(v.frame, point)) return YES;
    return NO;                                     // 平时其余区域穿透
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    for (UIView *v in self.subviews) {
        UIView *h = [v hitTest:point withEvent:event];
        if (h) return h;
    }
    return self.picking ? self : nil;
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!self.picking) return;
    UITouch *t = [touches anyObject];
    if (!t) return;
    CGPoint p = [t locationInView:self];
    self.picking = NO;
    [gFCBadgeBtn setTitle:@"取点中…" forState:UIControlStateNormal];
    FCPickAtPoint(p);
}

- (void)badgeTapped {
    self.picking = !self.picking;
    if (self.picking) {
        [gFCBadgeBtn setTitle:@"点广告元素 (再点取消)" forState:UIControlStateNormal];
        [gFCBadgeBtn setBackgroundColor:[[UIColor redColor] colorWithAlphaComponent:0.75]];
    } else {
        FCUpdateBadge();
    }
}

@end

static void FCEnsureBadgeWindow(void) {
    if (gFCBadgeWindow) return;
    CGRect s = [UIScreen mainScreen].bounds;
    gFCBadgeWindow = [[FCBadgeWindow alloc] initWithFrame:s];
    gFCBadgeWindow.windowLevel = UIWindowLevelAlert - 1;
    gFCBadgeWindow.backgroundColor = [UIColor clearColor];
    if (@available(iOS 13.0, *)) {
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if ([sc isKindOfClass:[UIWindowScene class]]) {
                gFCBadgeWindow.windowScene = (UIWindowScene *)sc; break;
            }
        }
    }
    CGFloat w = MIN(s.size.width - 20, 340);
    gFCBadgeBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    gFCBadgeBtn.tag = 9527;
    gFCBadgeBtn.frame = CGRectMake((s.size.width - w) / 2, 40, w, 20);
    gFCBadgeBtn.titleLabel.font = [UIFont systemFontOfSize:9];
    [gFCBadgeBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [gFCBadgeBtn setBackgroundColor:[[UIColor blackColor] colorWithAlphaComponent:0.5]];
    [gFCBadgeBtn addTarget:gFCBadgeWindow action:@selector(badgeTapped)
          forControlEvents:UIControlEventTouchUpInside];
    [gFCBadgeWindow addSubview:gFCBadgeBtn];
    gFCBadgeWindow.hidden = NO;
}

static void FCUpdateBadge(void) {
    if (!gFCBadgeBtn || !gFCBadgeWindow || gFCBadgeWindow.picking) return;  // 点选/取点中不覆盖
    NSString *top = NSStringFromClass([FCTopViewController() class]) ?: @"-";
    NSString *title = [NSString stringWithFormat:
        @"FCv3 规则%lu W%lu/E%lu/S%lu/O%lu H5%lu | 点我选广告 | %@",
        (unsigned long)FCUserRules().count, (unsigned long)gFCWindows,
        (unsigned long)gFCEvidences, (unsigned long)gFCSplashHits,
        (unsigned long)gFCOpEvidence, (unsigned long)gFCH5Hits, top];
    [gFCBadgeBtn setTitle:title forState:UIControlStateNormal];
    [gFCBadgeBtn setBackgroundColor:[[UIColor blackColor] colorWithAlphaComponent:0.5]];
}

static void FCShowBadgeMsg(NSString *msg) {
    if (!gFCBadgeBtn) return;
    [gFCBadgeBtn setTitle:[@"FCv3 " stringByAppendingString:msg] forState:UIControlStateNormal];
    [gFCBadgeBtn setBackgroundColor:[[UIColor colorWithRed:0.1 green:0.5 blue:0.2 alpha:0.8] colorWithAlphaComponent:0.85]];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ FCUpdateBadge(); });
}

#pragma mark - B 档：源头拦截宿主自有广告类

#ifdef FC_DEEP_HOOKS
static id FCVoidStub(id self, SEL _cmd) { return nil; }

static void FCSwizzleOwnMethods(NSString *clsName, NSArray<NSString *> *sels) {
    Class c = FCResolveClass(clsName); if (!c) return;
    for (NSString *selName in sels) {
        SEL s = NSSelectorFromString(selName);
        unsigned int n = 0; Method *list = class_copyMethodList(c, &n);
        for (unsigned int i = 0; i < n; i++)
            if (method_getName(list[i]) == s) {
                method_setImplementation(list[i], (IMP)FCVoidStub);
                FCLog(@"源头拦截 -[%@ %@]", clsName, selName); break;
            }
        free(list);
    }
}

static void FCInstallDeepHooks(void) {
    NSArray *table = @[
        @[@"FCSplashADSManager", @[@"show",@"start",@"requestSplashAd",@"loadSplashAd",@"showSplashAd"]],
        @[@"SplashAdManager",    @[@"show",@"start",@"load",@"requestAd",@"showSplash"]],
        @[@"SplashAdLibHandler", @[@"load",@"show",@"requestAd"]],
        @[@"CheckOutAlertInsertADViewController", @[@"viewDidLoad",@"show",@"loadAd"]],
        @[@"InterstScrAdLibTaku", @[@"show",@"load",@"requestAd"]],
        @[@"InterstScrAdLibUBIX", @[@"show",@"load",@"requestAd"]],
        @[@"OpenScrAdLibToBid",   @[@"show",@"load",@"requestAd"]],
        @[@"OpenScrAdLibUBIX",    @[@"show",@"load",@"requestAd"]],
    ];
    for (NSArray *row in table) FCSwizzleOwnMethods(row[0], row[1]);
}
#endif

#pragma mark - 入口

__attribute__((constructor))
static void FCAdBlockInit(void) {
    @autoreleasepool {
        FCLog(@"v3 载入，Bundle=%@", [[NSBundle mainBundle] bundleIdentifier]);
        gFCAttempts = [NSMapTable weakToStrongObjectsMapTable];
        dispatch_async(dispatch_get_main_queue(), ^{
            FCEnsureBadgeWindow();
            __block NSInteger fastTicks = 0;
            NSTimer *fast = [NSTimer scheduledTimerWithTimeInterval:0.10 repeats:YES
                              block:^(NSTimer *t){ FCScanOnce(); if (++fastTicks > 80) [t invalidate]; }];
            [[NSRunLoop mainRunLoop] addTimer:fast forMode:NSRunLoopCommonModes];
            __block NSInteger slowTicks = 0;
            NSTimer *slow = [NSTimer scheduledTimerWithTimeInterval:0.30 repeats:YES
                              block:^(NSTimer *t){
                FCScanOnce();
                if (++slowTicks % 5 == 0) FCInjectWebViewsForce(NO);
                FCUpdateBadge();
            }];
            [[NSRunLoop mainRunLoop] addTimer:slow forMode:NSRunLoopCommonModes];
#ifdef FC_DEEP_HOOKS
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ FCInstallDeepHooks(); });
#endif
        });
    }
}

//
//  FCAdBlockEntry.m —— 丰巢 (HiveConsumer) 去广告插件 v4
//
//  v4 相对 v3（真机三次反馈：浮标点不动 + 页面广告是原生控件）：
//    1) 浮标点不动根因：v3 浮标按钮 20pt/9pt 字且压在状态栏区域(y=40)，点击被系统
//       状态栏手势吃掉了。v4 移到状态栏下方(y=100)、加大到 36pt/11pt 字，
//       且改由 FCBadgeWindow 的 touchesEnded 自己判定点击（不依赖 UIControl target-action）。
//    2) 自动识别控件类型：点选取触点下最底层真实 view，向上查是否 WKWebView 子树：
//       - 是网页 → JS document.elementFromPoint 命中 DOM，隐藏 + 记文字规则
//       - 是原生 → 视图树向上找卡片容器，hidden=YES + 记文案规则
//    3) 原生规则定时扫描（FCApplyNativeRules），防 UICollectionViewCell 复用后复活。
//    4) 网页与原生规则统一存一份文字特征数组，两边共用，自动识别后自动 Persist。
//
//  硬约束：不 hook 系统类方法（自定义 UIWindow 子类重写 hitTest 不属于 hook）；
//  纯 .m 无 Logos；B 档只改宿主自有类；A 档零 hook；排除 Adress/Address 地址业务。
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
static void FCApplyNativeRules(void);
static void FCInjectWebViews(BOOL force);

#pragma mark - H5 脚本模板

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

// 网页拾取脚本（纯 ASCII，两个 %f 占位）
static NSString * const FCPickJSFmt =
@"(function(){var e=document.elementFromPoint(%f,%f);if(!e){return 'MISS';}"
"var t=e;for(var k=0;k<3;k++){var p=t.parentElement;if(!p||p===document.body){break;}"
"var pr=p.getBoundingClientRect();var tr=t.getBoundingClientRect();"
"if(tr.height>0&&pr.height<=tr.height*1.8&&pr.width<=window.innerWidth*0.97){t=p;}else{break;}}"
"var r=t.getBoundingClientRect();if(r.height>window.innerHeight*0.7){return 'TOOBIG';}"
"t.style.setProperty('display','none','important');t.__fcadDone=1;"
"var txt=(t.innerText||t.textContent||'');return txt.substring(0,40);})();";

#pragma mark - 用户规则持久化

static NSString * const FCUserRulesKey = @"FCAdBlockUserRules_v3";  // 保留 key，延续 v3 已存规则

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
    for (NSString *exist in a)
        if ([exist rangeOfString:rule].location != NSNotFound ||
            [rule rangeOfString:exist].location != NSNotFound) return;
    [a addObject:rule];
    if (a.count > 40) [a removeObjectsInRange:NSMakeRange(0, a.count - 40)];
    [[NSUserDefaults standardUserDefaults] setObject:a forKey:FCUserRulesKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    FCLog(@"记录规则：%@", rule);
}

static NSString *FCBuildInjectionJS(void) {
    NSMutableString *rjs = [NSMutableString stringWithString:@"["];
    for (NSString *s in FCUserRules()) [rjs appendFormat:@"'%@',", FCJSSafe(s)];
    [rjs appendString:@"]"];
    return [NSString stringWithFormat:FCJSAdCardsTemplate, rjs];
}

#pragma mark - 运行计数

static NSUInteger gFCWindows = 0, gFCEvidences = 0, gFCSplashHits = 0;
static NSUInteger gFCOpEvidence = 0, gFCWebViewFound = 0, gFCH5Hits = 0;
static NSUInteger gFCNativeHits = 0;

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

// 从规则挑一条最有辨识度的中文文案（最长），用于点选命中后持久化
static NSString *FCPickRuleText(UIView *root) {
    NSArray *texts = FCTextsOf(root);
    NSString *best = nil;
    for (NSString *s in texts) {
        if (s.length < 2) continue;
        BOOL hasCN = NO;
        for (NSUInteger i = 0; i < s.length; i++) {
            unichar c = [s characterAtIndex:i];
            if (c >= 0x4e00 && c <= 0x9fff) { hasCN = YES; break; }
        }
        if (hasCN && (!best || s.length > best.length)) best = s;
    }
    return best;
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

#pragma mark - 原生规则定时扫描（防 cell 复用复活）

static void FCApplyNativeRules(void) {
    NSArray *rules = FCUserRules();
    if (!rules.count) return;
    CGFloat sh = [UIScreen mainScreen].bounds.size.height;
    for (UIWindow *w in FCAllWindows()) {
        if ([NSStringFromClass([w class]) isEqualToString:@"FCBadgeWindow"]) continue;
        if (w.hidden || w.alpha < 0.01) continue;
        NSMutableArray<UIView *> *q = [NSMutableArray arrayWithObject:w];
        NSUInteger idx = 0;
        while (idx < q.count && idx < 900) {
            UIView *v = q[idx++];
            if (v.hidden || v.alpha < 0.05 || v.tag == 9527) continue;
            CGRect r = [v convertRect:v.bounds toView:nil];
            // 只处理"卡片级"尺寸：宽>=40、高 20~45% 屏，排除整页
            if (r.size.width < 40 || r.size.height < 20 || r.size.height > sh * 0.45) continue;
            NSString *cls = NSStringFromClass([v class]);
            if ([cls rangeOfString:@"TabBar"].location != NSNotFound ||
                [cls rangeOfString:@"NavigationBar"].location != NSNotFound) continue;
            NSArray *texts = FCTextsOf(v);
            BOOL hit = NO;
            for (NSString *s in texts) {
                for (NSString *rule in rules) {
                    if ([s rangeOfString:rule].location != NSNotFound) { hit = YES; break; }
                }
                if (hit) break;
            }
            if (hit) { v.hidden = YES; gFCNativeHits++; }
            for (UIView *sub in v.subviews) [q addObject:sub];
        }
    }
}

static void FCScanOnce(void) {
    NSArray *windows = FCAllWindows(); gFCWindows = windows.count;
    for (UIWindow *w in windows) {
        if (!w || w.hidden || w.alpha < 0.01) continue;
        NSString *wc = NSStringFromClass([w class]);
        if ([wc isEqualToString:@"FCBadgeWindow"]) continue;
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
    FCApplyNativeRules();
}

#pragma mark - 找触点下最底层真实 view（不依赖 hitTest:withEvent: 的 event）

static UIView *FCHitViewAtPoint(CGPoint p) {
    UIView *found = nil;
    for (UIWindow *w in FCAllWindows()) {
        if ([NSStringFromClass([w class]) isEqualToString:@"FCBadgeWindow"]) continue;
        if (w.hidden || w.alpha < 0.01) continue;
        if (!CGRectContainsPoint(w.bounds, p)) continue;
        NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:w];
        while (stack.count) {
            UIView *v = stack.lastObject; [stack removeLastObject];
            if (v.hidden || v.alpha < 0.05 || v.tag == 9527) continue;
            CGRect r = [v convertRect:v.bounds toView:nil];
            if (!CGRectContainsPoint(r, p)) continue;
            found = v;                       // 记录最深命中，继续深入
            for (UIView *s in v.subviews) [stack addObject:s];
        }
    }
    return found;
}

// 从命中的 view 向上找合适的原生卡片容器（排除整页与系统栏）
static UIView *FCCardContainerFrom(UIView *hit) {
    CGFloat sw = [UIScreen mainScreen].bounds.size.width;
    CGFloat sh = [UIScreen mainScreen].bounds.size.height;
    UIView *cur = hit, *best = nil;
    int guard = 0;
    while (cur && guard++ < 8) {
        UIView *sup = cur.superview;
        if (!sup || [sup isKindOfClass:[UIWindow class]]) break;
        NSString *cls = NSStringFromClass([sup class]);
        if ([cls rangeOfString:@"TabBar"].location != NSNotFound ||
            [cls rangeOfString:@"NavigationBar"].location != NSNotFound) break;
        CGRect r = [sup convertRect:sup.bounds toView:nil];
        if (r.size.width >= 60 && r.size.width <= sw + 1 &&
            r.size.height >= 24 && r.size.height <= sh * 0.45) best = sup;
        cur = sup;
    }
    return best ?: hit;
}

#pragma mark - 点选拾取：自动识别网页/原生

static void FCPickAtPoint(CGPoint screenP) {
    Class wk = NSClassFromString(@"WKWebView");
    UIView *hit = FCHitViewAtPoint(screenP);
    if (!hit) { FCShowBadgeMsg(@"未命中元素"); return; }

    // 判断命中 view 是否处在 WKWebView 子树内
    UIView *cur = hit, *web = nil;
    while (cur) {
        if (wk && [cur isKindOfClass:wk]) { web = cur; break; }
        cur = cur.superview;
    }

    if (web) {
        // ——— 网页拾取 ———
        SEL sel = NSSelectorFromString(@"evaluateJavaScript:completionHandler:");
        if (![web respondsToSelector:sel]) { FCShowBadgeMsg(@"网页注入不可用"); return; }
        IMP imp = [web methodForSelector:sel]; if (!imp) { FCShowBadgeMsg(@"网页注入不可用"); return; }
        CGPoint lp = [web convertPoint:screenP fromView:nil];
        NSString *js = [NSString stringWithFormat:FCPickJSFmt, lp.x, lp.y];
        ((void (*)(id, SEL, NSString *, void (^)(id, NSError *)))imp)
            (web, sel, js, ^(id result, NSError *err){
                if (!err && [result isKindOfClass:[NSString class]]) {
                    NSString *txt = (NSString *)result;
                    if (txt.length >= 2 && ![txt hasPrefix:@"MISS"] && ![txt hasPrefix:@"TOOBIG"]) {
                        FCAddUserRule(txt);
                        dispatch_async(dispatch_get_main_queue(), ^{
                            FCInjectWebViews(NO); FCShowBadgeMsg(@"网页·已隐藏并记住");
                        });
                        return;
                    }
                }
                dispatch_async(dispatch_get_main_queue(), ^{ FCShowBadgeMsg(@"网页·未命中元素"); });
            });
    } else {
        // ——— 原生拾取 ———
        UIView *card = FCCardContainerFrom(hit);
        NSString *ruleText = FCPickRuleText(card);
        card.hidden = YES;
        gFCNativeHits++;
        if (ruleText.length >= 2) FCAddUserRule(ruleText);
        FCShowBadgeMsg(ruleText.length >= 2 ? @"原生·已隐藏并记住" : @"原生·已隐藏");
    }
}

#pragma mark - WKWebView 注入

static void FCInjectWebViews(BOOL force) {
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

#pragma mark - 常驻浮标窗口（独立 window；点击由 touchesEnded 自己处理）

@interface FCBadgeWindow : UIWindow
@property (nonatomic, assign) BOOL picking;
@end

static UIView *gFCBadgeBar = nil;
static UILabel *gFCBadgeLabel = nil;
static CGRect gFCBadgeFrame = CGRectZero;
static FCBadgeWindow *gFCBadgeWindow = nil;

@implementation FCBadgeWindow

- (BOOL)canBecomeKeyWindow { return NO; }

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.picking) return YES;                              // 点选模式：全屏接住
    return CGRectContainsPoint(gFCBadgeFrame, point);          // 平时：只有浮标区域
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    return [self pointInside:point withEvent:event] ? self : nil;  // touch 交给 window 自己
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *t = [touches anyObject]; if (!t) return;
    CGPoint p = [t locationInView:self];
    if (CGRectContainsPoint(gFCBadgeFrame, p)) {               // 点浮标本身：进入/取消点选
        self.picking = !self.picking;
        if (self.picking) {
            gFCBadgeBar.backgroundColor = [[UIColor redColor] colorWithAlphaComponent:0.8];
            gFCBadgeLabel.text = @"点页面上的广告元素（再点此取消）";
        } else {
            FCUpdateBadge();
        }
        return;
    }
    if (self.picking) {                                        // 点选模式点页面：拾取
        self.picking = NO;
        FCUpdateBadge();
        FCPickAtPoint(p);
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
    // 移到状态栏下方（避开系统状态栏手势），加大点击区
    CGFloat w = MIN(s.size.width - 24, 360);
    gFCBadgeFrame = CGRectMake((s.size.width - w) / 2, 100, w, 36);
    gFCBadgeBar = [[UIView alloc] initWithFrame:gFCBadgeFrame];
    gFCBadgeBar.tag = 9527;
    gFCBadgeBar.userInteractionEnabled = NO;                   // touch 由 window 统一处理
    gFCBadgeBar.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
    gFCBadgeBar.layer.cornerRadius = 8;
    gFCBadgeBar.clipsToBounds = YES;
    gFCBadgeLabel = [[UILabel alloc] initWithFrame:CGRectInset(gFCBadgeBar.bounds, 6, 2)];
    gFCBadgeLabel.font = [UIFont systemFontOfSize:11];
    gFCBadgeLabel.textColor = [UIColor whiteColor];
    gFCBadgeLabel.textAlignment = NSTextAlignmentCenter;
    gFCBadgeLabel.adjustsFontSizeToFitWidth = YES;
    gFCBadgeLabel.numberOfLines = 2;
    [gFCBadgeBar addSubview:gFCBadgeLabel];
    [gFCBadgeWindow addSubview:gFCBadgeBar];
    gFCBadgeWindow.hidden = NO;
}

static void FCUpdateBadge(void) {
    if (!gFCBadgeLabel || !gFCBadgeWindow || gFCBadgeWindow.picking) return;
    NSString *top = NSStringFromClass([FCTopViewController() class]) ?: @"-";
    gFCBadgeLabel.text = [NSString stringWithFormat:
        @"FCv4 规则%lu 原%lu W%lu H5%lu | 点我选广告 | %@",
        (unsigned long)FCUserRules().count, (unsigned long)gFCNativeHits,
        (unsigned long)gFCWebViewFound, (unsigned long)gFCH5Hits, top];
    gFCBadgeBar.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
}

static void FCShowBadgeMsg(NSString *msg) {
    if (!gFCBadgeLabel) return;
    gFCBadgeLabel.text = [@"FCv4 " stringByAppendingString:msg];
    gFCBadgeBar.backgroundColor = [[UIColor colorWithRed:0.1 green:0.5 blue:0.2 alpha:0.85] colorWithAlphaComponent:0.85];
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
        FCLog(@"v4 载入，Bundle=%@", [[NSBundle mainBundle] bundleIdentifier]);
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
                if (++slowTicks % 5 == 0) FCInjectWebViews(NO);
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

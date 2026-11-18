//
//  FCAdBlockEntry.m —— 丰巢 (HiveConsumer) 去广告插件 v5
//
//  v5 相对 v4（真机四次反馈：浮标要能拖/边缘吸附小白条 + 规则可视化编辑 + 返回页面后失效）：
//    1) 浮标可拖动：touchesMoved 更新位置；松手靠近左右边缘自动收成「小白条」吸附贴边；
//       点小白条展开回完整浮标。tap 完整浮标弹出操作菜单（点选广告/规则管理/复位）。
//       区分 tap 与 drag（位移阈值），拖动不误触发菜单。
//    2) 规则管理面板：独立 gFCPanelWindow（canBecomeKeyWindow=YES，可弹键盘），列出已生效规则，
//       每条是可编辑 UITextField + 删除按钮，支持新增/完成；写回 NSUserDefaults 并即时重注入。
//    3) 修复「进其他页面再返回隐藏失效」：文案收集读 attributedText.string；规则匹配改双向
//       （规则⊇文案 或 文案⊇规则，短串设 3 字门槛防误伤）；FCApplyNativeRules 每次扫描强制重扫，
//       不设启动后轮数上限（技能第九节：页面返回后重建，必须周期性幂等重扫）。
//
//  沿用 v4：点选自动识别网页(WKWebView→JS elementFromPoint)/原生(视图树容器→hidden)；
//  开屏强特征；网页规则 JS 注入；B 档源头拦截宿主自有类；排除 Adress/Address。
//
//  硬约束：不 hook 系统类方法（自定义 UIWindow 子类重写 hitTest 不属于 hook）；
//  纯 .m 无 Logos；B 档只改宿主自有类；A 档零 hook。
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#define FCLog(fmt, ...) NSLog((@"[FCAdBlock] " fmt), ##__VA_ARGS__)

#pragma mark - 前置声明

static void FCUpdateBadge(void);
static void FCShowBadgeMsg(NSString *msg);
static NSArray<NSString *> *FCUserRules(void);
static void FCSetUserRules(NSArray *rules);
static NSString *FCJSSafe(NSString *s);
static NSString *FCBuildInjectionJS(void);
static void FCApplyNativeRules(void);
static void FCInjectWebViews(BOOL force);
static void FCPickAtPoint(CGPoint p);
static void FCShowActionMenu(void);
static void FCShowRulePanel(void);
static void FCHidePanel(void);
static void FCCloseRulePanelAndCommit(BOOL commit);
static NSArray<NSString *> *FCTextsOf(UIView *root);
static BOOL FCRuleMatchesText(NSString *rule, NSString *text);

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

static NSString * const FCPickJSFmt =
@"(function(){var e=document.elementFromPoint(%f,%f);if(!e){return 'MISS';}"
"var t=e;for(var k=0;k<3;k++){var p=t.parentElement;if(!p||p===document.body){break;}"
"var pr=p.getBoundingClientRect();var tr=t.getBoundingClientRect();"
"if(tr.height>0&&pr.height<=tr.height*1.8&&pr.width<=window.innerWidth*0.97){t=p;}else{break;}}"
"var r=t.getBoundingClientRect();if(r.height>window.innerHeight*0.7){return 'TOOBIG';}"
"t.style.setProperty('display','none','important');t.__fcadDone=1;"
"var txt=(t.innerText||t.textContent||'');return txt.substring(0,40);})();";

#pragma mark - 用户规则持久化

static NSString * const FCUserRulesKey = @"FCAdBlockUserRules_v3";  // 保留 key，延续已存规则

static NSArray<NSString *> *FCUserRules(void) {
    NSArray *a = [[NSUserDefaults standardUserDefaults] arrayForKey:FCUserRulesKey];
    return a ?: @[];
}

static void FCSetUserRules(NSArray *rules) {
    NSMutableArray *clean = [NSMutableArray array];
    for (NSString *s in rules) {
        NSString *v = FCJSSafe(s);
        if (v.length >= 2 && ![clean containsObject:v]) [clean addObject:v];
    }
    [[NSUserDefaults standardUserDefaults] setObject:clean forKey:FCUserRulesKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

static NSString *FCJSSafe(NSString *s) {
    s = [s stringByReplacingOccurrencesOfString:@"'" withString:@""];
    s = [s stringByReplacingOccurrencesOfString:@"\\" withString:@""];
    s = [s stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    s = [s stringByReplacingOccurrencesOfString:@"\r" withString:@" "];
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (s.length > 40) s = [s substringToIndex:40];   // v5：放宽到 40，保留更多辨识度
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
    FCSetUserRules(a);
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

#pragma mark - 双向规则匹配（v5 修复返回失效核心）

static BOOL FCRuleMatchesText(NSString *rule, NSString *text) {
    if (rule.length < 3 || text.length < 2) return NO;   // 短规则/空文案不匹配，防误伤
    if ([text rangeOfString:rule].location != NSNotFound) return YES;       // 文案含完整规则
    if (text.length >= 3 && [rule rangeOfString:text].location != NSNotFound) return YES;  // 规则含文案（重建后文案变短）
    return NO;
}

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

#pragma mark - 视图树（v5：读 attributedText）

static void FCCollectText(UIView *v, NSMutableArray<NSString *> *out, int depth, int *budget) {
    if (!v || depth > 10 || out.count > 320 || *budget <= 0) return;
    *budget -= 1;
    if (v.hidden || v.alpha < 0.05 || v.tag == 9527 || v.tag == 9528) return;
    NSString *s = nil;
    if ([v isKindOfClass:[UILabel class]]) {
        s = ((UILabel *)v).text;
        if (!s.length) s = ((UILabel *)v).attributedText.string;   // v5：富文本兜底
    } else if ([v isKindOfClass:[UIButton class]]) {
        s = ((UIButton *)v).currentTitle;
        if (!s.length) s = ((UIButton *)v).titleLabel.attributedText.string;
    } else if ([v isKindOfClass:[UITextField class]]) s = ((UITextField *)v).text;
    if (s.length && s.length < 120) [out addObject:s];
    NSString *a = v.accessibilityLabel;
    if (a.length && a.length < 60) [out addObject:a];
    for (UIView *sub in v.subviews) FCCollectText(sub, out, depth + 1, budget);
}

static NSArray<NSString *> *FCTextsOf(UIView *root) {
    NSMutableArray *out = [NSMutableArray array]; int budget = 800;   // v5：放宽预算
    FCCollectText(root, out, 0, &budget);
    return out;
}

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
        if (v.tag == 9527 || v.tag == 9528) continue;
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
        if (s == mainView || s.tag == 9527 || s.tag == 9528) continue;
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

#pragma mark - 原生规则定时扫描（v5：双向匹配 + 强制重扫）

static void FCApplyNativeRules(void) {
    NSArray *rules = FCUserRules();
    if (!rules.count) return;
    CGFloat sh = [UIScreen mainScreen].bounds.size.height;
    for (UIWindow *w in FCAllWindows()) {
        NSString *wc = NSStringFromClass([w class]);
        if ([wc isEqualToString:@"FCBadgeWindow"] || [wc isEqualToString:@"FCPanelWindow"]) continue;
        if (w.hidden || w.alpha < 0.01) continue;
        NSMutableArray<UIView *> *q = [NSMutableArray arrayWithObject:w];
        NSUInteger idx = 0;
        while (idx < q.count && idx < 1400) {
            UIView *v = q[idx++];
            if (v.tag == 9527 || v.tag == 9528) continue;
            CGRect r = [v convertRect:v.bounds toView:nil];
            // 卡片级尺寸：宽>=40、高 18~50% 屏，排除整页与已隐藏（已隐藏的无需再处理）
            if (v.hidden || r.size.width < 40 || r.size.height < 18 || r.size.height > sh * 0.5) {
                for (UIView *sub in v.subviews) [q addObject:sub];
                continue;
            }
            NSString *cls = NSStringFromClass([v class]);
            if ([cls rangeOfString:@"TabBar"].location != NSNotFound ||
                [cls rangeOfString:@"NavigationBar"].location != NSNotFound) {
                for (UIView *sub in v.subviews) [q addObject:sub];
                continue;
            }
            NSArray *texts = FCTextsOf(v);
            BOOL hit = NO;
            for (NSString *s in texts) {
                for (NSString *rule in rules) {
                    if (FCRuleMatchesText(rule, s)) { hit = YES; break; }
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
        if ([wc isEqualToString:@"FCBadgeWindow"] || [wc isEqualToString:@"FCPanelWindow"]) continue;
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
                if (s == mainView || s.tag == 9527 || s.tag == 9528) continue;
                NSString *sc = NSStringFromClass([s class]); NSArray *st = FCTextsOf(s);
                if (FCClassIsAd(sc) || FCTextsAreAd(st) || FCTextsAreSplash(st)) {
                    [s removeFromSuperview]; if (FCTextsAreSplash(st)) gFCSplashHits++;
                }
            }
        }
    }
    FCApplyNativeRules();
}

#pragma mark - 找触点下最底层 view / 原生容器

static UIView *FCHitViewAtPoint(CGPoint p) {
    UIView *found = nil;
    for (UIWindow *w in FCAllWindows()) {
        NSString *wc = NSStringFromClass([w class]);
        if ([wc isEqualToString:@"FCBadgeWindow"] || [wc isEqualToString:@"FCPanelWindow"]) continue;
        if (w.hidden || w.alpha < 0.01) continue;
        if (!CGRectContainsPoint(w.bounds, p)) continue;
        NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:w];
        while (stack.count) {
            UIView *v = stack.lastObject; [stack removeLastObject];
            if (v.hidden || v.alpha < 0.05 || v.tag == 9527 || v.tag == 9528) continue;
            CGRect r = [v convertRect:v.bounds toView:nil];
            if (!CGRectContainsPoint(r, p)) continue;
            found = v;
            for (UIView *s in v.subviews) [stack addObject:s];
        }
    }
    return found;
}

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
            r.size.height >= 24 && r.size.height <= sh * 0.5) best = sup;
        cur = sup;
    }
    return best ?: hit;
}

#pragma mark - 点选拾取

static void FCPickAtPoint(CGPoint screenP) {
    Class wk = NSClassFromString(@"WKWebView");
    UIView *hit = FCHitViewAtPoint(screenP);
    if (!hit) { FCShowBadgeMsg(@"未命中元素"); return; }
    UIView *cur = hit, *web = nil;
    while (cur) {
        if (wk && [cur isKindOfClass:wk]) { web = cur; break; }
        cur = cur.superview;
    }
    if (web) {
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
        UIView *card = FCCardContainerFrom(hit);
        NSString *ruleText = FCPickRuleText(card);
        card.hidden = YES;
        gFCNativeHits++;
        if (ruleText.length >= 2) FCAddUserRule(ruleText);
        FCShowBadgeMsg(ruleText.length >= 2 ? @"原生·已隐藏并记住" : @"原生·已隐藏");
    }
}

static void FCInjectWebViews(BOOL force) {
    Class wk = NSClassFromString(@"WKWebView"); if (!wk) return;
    SEL sel = NSSelectorFromString(@"evaluateJavaScript:completionHandler:");
    NSDate *now = [NSDate date]; static char kKey;
    gFCWebViewFound = 0;
    NSString *js = FCBuildInjectionJS();
    for (UIWindow *w in FCAllWindows()) {
        NSString *wc = NSStringFromClass([w class]);
        if ([wc isEqualToString:@"FCBadgeWindow"] || [wc isEqualToString:@"FCPanelWindow"]) continue;
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

#pragma mark - 规则管理面板（独立可成 key 的 window，支持键盘编辑）

@interface FCPanelWindow : UIWindow <UIGestureRecognizerDelegate>
@end

static FCPanelWindow *gFCPanelWindow = nil;
static UIView *gFCRulePanel = nil;
static UIView *gFCRuleCard = nil;      // v5.1：卡片容器，供空白点击判定

@implementation FCPanelWindow
- (BOOL)canBecomeKeyWindow { return YES; }   // 规则编辑需要键盘
// v5.1：面板「完成 / 点空白」统一走这里，真实收集输入框并保存
- (void)fcCloseAndCommit { FCCloseRulePanelAndCommit(YES); }
// v5.1：只让「点 card 外的遮罩」触发关闭，点输入框/按钮时不误关
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)touch {
    UIView *tv = touch.view;
    if (!tv || tv == gFCRulePanel) return YES;
    // 触摸落在 card 内（输入框/按钮）时交给控件自己处理
    UIView *cur = tv;
    while (cur && cur != gFCRulePanel) {
        if (cur == gFCRuleCard) return NO;
        cur = cur.superview;
    }
    return YES;
}
@end

// 用弱引用包装 UITextField，避免数组强持有导致的复杂释放问题
static void FCCloseRulePanelAndCommit(BOOL commit) {
    if (commit && gFCRulePanel) {
        NSMutableArray *rules = [NSMutableArray array];
        // v5.1 修复：UITextField 挂在 card 上、card 挂在 mask(gFCRulePanel) 上，
        // 只遍历直接子视图收集不到任何输入框 → 保存即清空规则。改为整棵子树 BFS。
        NSMutableArray<UIView *> *q = [NSMutableArray arrayWithObject:gFCRulePanel];
        NSUInteger idx = 0;
        while (idx < q.count) {
            UIView *v = q[idx++];
            if ([v isKindOfClass:[UITextField class]]) {
                NSString *t = ((UITextField *)v).text;
                if (t.length) [rules addObject:t];
            }
            for (UIView *sub in v.subviews) [q addObject:sub];
        }
        FCSetUserRules(rules);
        FCInjectWebViews(YES);
        FCUpdateBadge();
        FCLog(@"规则面板保存 %lu 条", (unsigned long)rules.count);
    }
    [gFCRulePanel removeFromSuperview];
    gFCRulePanel = nil;
    gFCRuleCard = nil;
    if (gFCPanelWindow) {
        gFCPanelWindow.hidden = YES;
    }
}

static void FCShowRulePanel(void) {
    FCHidePanel();
    if (!gFCPanelWindow) {
        CGRect s = [UIScreen mainScreen].bounds;
        gFCPanelWindow = [[FCPanelWindow alloc] initWithFrame:s];
        gFCPanelWindow.windowLevel = UIWindowLevelAlert + 100;
        if (@available(iOS 13.0, *)) {
            for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
                if ([sc isKindOfClass:[UIWindowScene class]]) {
                    gFCPanelWindow.windowScene = (UIWindowScene *)sc; break;
                }
            }
        }
    }
    CGRect s = [UIScreen mainScreen].bounds;
    gFCPanelWindow.frame = s;
    gFCPanelWindow.hidden = NO;
    [gFCPanelWindow makeKeyWindow];

    // 背景遮罩（点空白处关闭并保存）
    UIView *mask = [[UIView alloc] initWithFrame:s];
    mask.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.45];
    mask.tag = 9528;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:gFCPanelWindow
                                  action:@selector(fcCloseAndCommit)];
    [mask addGestureRecognizer:tap];
    [gFCPanelWindow addSubview:mask];
    gFCRulePanel = mask;

    CGFloat w = MIN(s.size.width - 32, 380);
    CGFloat cardH = MIN(s.size.height - 160, 560);
    CGFloat x = (s.size.width - w) / 2;
    CGFloat y = (s.size.height - cardH) / 2;
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(x, y, w, cardH)];
    card.backgroundColor = [UIColor colorWithRed:0.97 green:0.97 blue:0.98 alpha:1.0];
    card.layer.cornerRadius = 14; card.clipsToBounds = YES;
    card.tag = 9528;
    [mask addSubview:card];
    gFCRuleCard = card;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, w - 32, 30)];
    title.text = @"已生效规则（可直接修改，点空白保存）";
    title.font = [UIFont boldSystemFontOfSize:14];
    title.textColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.12 alpha:1];
    [card addSubview:title];

    CGFloat rowY = 50;
    NSArray *rules = FCUserRules();
    for (NSUInteger i = 0; i < rules.count && rowY < cardH - 110; i++) {
        UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(16, rowY, w - 70, 34)];
        tf.text = rules[i];
        tf.font = [UIFont systemFontOfSize:12];
        tf.borderStyle = UITextBorderStyleRoundedRect;
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        [card addSubview:tf];
        rowY += 40;
    }
    // 至少留一个空行方便新增
    if (rowY < cardH - 110) {
        UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(16, rowY, w - 70, 34)];
        tf.placeholder = @"新增规则（广告文字）";
        tf.font = [UIFont systemFontOfSize:12];
        tf.borderStyle = UITextBorderStyleRoundedRect;
        [card addSubview:tf];
        rowY += 40;
    }

    // 「完成」按钮（保存并关闭）
    UIButton *done = [UIButton buttonWithType:UIButtonTypeSystem];
    done.frame = CGRectMake(w - 62, 14, 48, 26);
    [done setTitle:@"完成" forState:UIControlStateNormal];
    [done addTarget:gFCPanelWindow action:@selector(fcCloseAndCommit) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:done];
}

// 面板的按钮/空白关闭统一由 panel window 的 touchesEnded 处理（见下）

static void FCHidePanel(void) {
    FCCloseRulePanelAndCommit(YES);
}

#pragma mark - 常驻浮标窗口（v5：可拖动 / 边缘吸附小白条 / tap 菜单）

@interface FCBadgeWindow : UIWindow
@property (nonatomic, assign) BOOL picking;
- (void)expandBadgeFrame;
- (void)collapseToEdge;
@end

static UIView *gFCBadgeBar = nil;
static UILabel *gFCBadgeLabel = nil;
static CGRect gFCBadgeFrame = {0};
static FCBadgeWindow *gFCBadgeWindow = nil;
static BOOL gFCBadgeCollapsed = NO;      // 是否为吸附小白条
static NSInteger gFCBadgeSide = 0;       // 吸附边：0 左 / 1 右
static CGPoint gFCTouchStart = {0};
static BOOL gFCDidDrag = NO;

@implementation FCBadgeWindow

- (BOOL)canBecomeKeyWindow { return NO; }

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.picking) return YES;
    return CGRectContainsPoint(gFCBadgeFrame, point);
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    return [self pointInside:point withEvent:event] ? self : nil;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *t = [touches anyObject];
    gFCTouchStart = [t locationInView:self];
    gFCDidDrag = NO;
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.picking) return;
    UITouch *t = [touches anyObject];
    CGPoint p = [t locationInView:self];
    CGFloat dx = p.x - gFCTouchStart.x, dy = p.y - gFCTouchStart.y;
    if (fabs(dx) + fabs(dy) > 6) gFCDidDrag = YES;
    if (!gFCDidDrag) return;
    CGRect f = gFCBadgeFrame;
    f.origin.x += dx; f.origin.y += dy;
    CGRect s = self.bounds;
    f.origin.x = MAX(0, MIN(f.origin.x, s.size.width - f.size.width));
    f.origin.y = MAX(60, MIN(f.origin.y, s.size.height - f.size.height - 40));
    gFCBadgeFrame = f;
    gFCBadgeBar.frame = f;
    gFCTouchStart = p;
    if (gFCBadgeCollapsed) { gFCBadgeCollapsed = NO; [self expandBadgeFrame]; }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *t = [touches anyObject]; if (!t) return;
    CGPoint p = [t locationInView:self];

    if (self.picking) {                                   // 点选模式：拾取
        self.picking = NO;
        FCUpdateBadge();
        FCPickAtPoint(p);
        return;
    }
    if (gFCDidDrag) {                                     // 拖动结束：边缘吸附
        CGRect s = self.bounds;
        CGFloat cx = CGRectGetMidX(gFCBadgeFrame);
        if (cx < 60) { gFCBadgeSide = 0; [self collapseToEdge]; }
        else if (cx > s.size.width - 60) { gFCBadgeSide = 1; [self collapseToEdge]; }
        else { gFCBadgeCollapsed = NO; [self expandBadgeFrame]; }
        FCUpdateBadge();
        return;
    }
    // 纯 tap
    if (gFCBadgeCollapsed) {                              // 小白条 → 展开
        gFCBadgeCollapsed = NO;
        [self expandBadgeFrame];
        FCUpdateBadge();
    } else {
        FCShowActionMenu();                               // 完整浮标 → 操作菜单
    }
}

- (void)expandBadgeFrame {
    CGRect s = self.bounds;
    CGFloat w = MIN(s.size.width - 24, 360);
    CGFloat h = 40;
    CGFloat x = gFCBadgeSide == 1 ? (s.size.width - w - 6) : 6;
    CGFloat y = MIN(MAX(gFCBadgeFrame.origin.y, 100), s.size.height - h - 120);
    gFCBadgeFrame = CGRectMake(x, y, w, h);
    gFCBadgeBar.frame = gFCBadgeFrame;
    gFCBadgeLabel.frame = CGRectInset(gFCBadgeBar.bounds, 6, 2);
}

- (void)collapseToEdge {
    CGRect s = self.bounds;
    CGFloat w = 14, h = 56;
    CGFloat x = gFCBadgeSide == 1 ? (s.size.width - w) : 0;
    CGFloat y = MIN(MAX(CGRectGetMidY(gFCBadgeFrame) - h / 2, 120), s.size.height - h - 100);
    gFCBadgeCollapsed = YES;
    gFCBadgeFrame = CGRectMake(x, y, w, h);
    gFCBadgeBar.frame = gFCBadgeFrame;
    gFCBadgeLabel.frame = gFCBadgeBar.bounds;
    gFCBadgeLabel.text = @"⋮";
    gFCBadgeBar.backgroundColor = [[UIColor colorWithRed:0.2 green:0.5 blue:0.9 alpha:0.8] colorWithAlphaComponent:0.85];
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
    CGFloat w = MIN(s.size.width - 24, 360);
    gFCBadgeFrame = CGRectMake((s.size.width - w) / 2, 108, w, 40);
    gFCBadgeBar = [[UIView alloc] initWithFrame:gFCBadgeFrame];
    gFCBadgeBar.tag = 9527;
    gFCBadgeBar.userInteractionEnabled = NO;
    gFCBadgeBar.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
    gFCBadgeBar.layer.cornerRadius = 8; gFCBadgeBar.clipsToBounds = YES;
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
    if (!gFCBadgeLabel || !gFCBadgeWindow) return;
    if (gFCBadgeWindow.picking) return;
    if (gFCBadgeCollapsed) return;                        // 小白条不刷文字
    NSString *top = NSStringFromClass([FCTopViewController() class]) ?: @"-";
    gFCBadgeLabel.text = [NSString stringWithFormat:
        @"FCv5 规则%lu 原%lu H5%lu | 点我操作 | %@",
        (unsigned long)FCUserRules().count, (unsigned long)gFCNativeHits,
        (unsigned long)gFCH5Hits, top];
    gFCBadgeBar.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
}

static void FCShowBadgeMsg(NSString *msg) {
    if (!gFCBadgeLabel) return;
    if (gFCBadgeCollapsed) {
        gFCBadgeCollapsed = NO;
        [gFCBadgeWindow expandBadgeFrame];
    }
    gFCBadgeLabel.text = [@"FCv5 " stringByAppendingString:msg];
    gFCBadgeBar.backgroundColor = [[UIColor colorWithRed:0.1 green:0.5 blue:0.2 alpha:0.85] colorWithAlphaComponent:0.85];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ FCUpdateBadge(); });
}

// 操作菜单：用系统 UIAlertController（present 到顶层 VC），避免自绘触摸冲突
static void FCShowActionMenu(void) {
    UIViewController *top = FCTopViewController();
    if (!top) { FCShowBadgeMsg(@"无顶层页面"); return; }
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"FCAdBlock v5"
                              message:@"选择操作" preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"点选广告元素" style:UIAlertActionStyleDefault
                 handler:^(UIAlertAction *a){ gFCBadgeWindow.picking = YES;
                     gFCBadgeLabel.text = @"点页面上的广告元素（再点浮标取消）";
                     gFCBadgeBar.backgroundColor = [[UIColor redColor] colorWithAlphaComponent:0.8]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"管理规则（查看/编辑/新增）" style:UIAlertActionStyleDefault
                 handler:^(UIAlertAction *a){ FCShowRulePanel(); }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"浮标复位" style:UIAlertActionStyleDefault
                 handler:^(UIAlertAction *a){ gFCBadgeCollapsed = NO; gFCBadgeSide = 0;
                     [gFCBadgeWindow expandBadgeFrame]; FCUpdateBadge(); }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (ac.popoverPresentationController) ac.popoverPresentationController.sourceView = gFCBadgeBar;
    [top presentViewController:ac animated:YES completion:nil];
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
        FCLog(@"v5 载入，Bundle=%@", [[NSBundle mainBundle] bundleIdentifier]);
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

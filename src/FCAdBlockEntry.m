//
//  FCAdBlockEntry.m —— 通用去广告插件 v17（丰巢 HiveConsumer + 淘宝 Taobao4iPhone）
//
//  v17 相对 v16（老大要求：全面分析淘宝 10.56.10 广告，补进列表，标注广告类型，适配通用）：
//    ①新增「通用广告类型体系」FCAdTypeClassTable——7 大类型（开屏/激励/插屏/横幅/信息流/
//      运营位/联盟），丰巢类(v14 真机实证) + 淘宝类(10.56.10 主二进制 17385 个 ObjC 类静态
//      提取, 74 个高置信类)统一进表，新增 App 只加一行即可。
//    ②FCClassIsAd 改为「权威表精确匹配 + 通用强特征词根兜底」双通道，保留 Adress/Address 防护。
//    ③FCResolveClass 支持多宿主命名空间（HiveConsumer. / Taobao4iPhone. / 无前缀 ObjC）。
//    ④FCAdBlock.plist 增加淘宝 Bundle，巨魔注入不读 plist 但 deb/插桩路径也需要能命中。
//    ⑤诊断面板每条命中标注广告类型；规则面板类型标签补充类型色。
//    ⑥B 档 deep hook 增加淘宝开屏/激励/联盟 SDK 源头拦截。
//    淘宝广告架构证据：SPSplash*/TBBootImage*Splash/TXSplash*(开屏)、TBRewardKit/
//    TBCashRewardService(激励)、TBTDBanner*(横幅)、AKTsAlimamaAdAbility/Munion*/(联盟)、
//    MMAdBizSDKBundle.bundle；中文广告文案多在服务端动态下发，主二进制命中少。
//    静态分析未真机验证淘宝，标注为「静态推断」，以真机反馈为准。
//
//  v14 相对 v13（真机浮标「FCv13 规则9 内0 挡0 原19 H50」，运营位仍不动）：
//    连续多版盲改无效——停止猜测，改为「诊断优先」。真因待定：内0挡0 说明原生扫描
//    完全没匹配到这些运营位文字，它们极可能在 WKWebView 里（H5）或文字画在切图上。
//    v14：①浮标菜单加「诊断当前页面」——把原生视图树(class+文字+frame)和
//    WKWebView 的 DOM 文本/图片名全部导出到浮标可滚动文本框，截图即可一次定位；
//    ②网页 sweep 加固：glob 匹配 alt/aria-label、放宽文字长度、body 直接文本兜底。
//
//  v13 相对 v12（老大问「规则里为什么都是文字」+ 浮标内0挡0）：
//    根因：点选拾取只取「最长中文串」当规则（FCPickRuleText），图片型运营位
//    （文字画在图片里、无真实文本节点）根本记不住 → 规则面板清一色「文」。
//    v13 点选改为「元素指纹」：①网页生成 CSS 选择器路径存 `sel:` 规则，注入脚本
//    用 querySelectorAll 精确命中；②原生存 `cls:类名` + 屏幕相对位置 `pos:`；
//    ③规则面板新增「选/位」类型标签；④注入脚本加版本号 __fcadVer，避免
//    __fcadLoaded 幂等导致旧词表闭包常驻、新关键词不生效。
//
//  v12 相对 v11（真机十一次反馈：「FCv11 规则8 内0」，部分运营位仍没隐藏）：
//    截图「我的」页明确显示 寄件省钱卡/查价领返现/100元寄件券包，但内置命中 0。
//    两个原因：①v11 的内置闸门要求宽≥120pt，而这些卡片实测约 109pt，全被挡；
//    ②「100元寄件券包 / 69.9元 / 马上抢 / 洗护券」不在内置关键词里（旧词是
//      「百元券包 / 69.9元抢」），文案对不上。v12 放宽闸门到 90pt、按截图补词、
//      H5 的 K 同步，并在浮标加「挡N」显示被闸门拦下的命中数供诊断。
//
//  v11 相对 v10（真机十次反馈：重启后隐藏仍没生效，规则 5 条都在）：
//    真因不是持久化——截图浮标「FCv10 规则5」证明规则完好。是**内置运营广告关键词
//    只喂给 FCTextsAreOperationAd 做诊断计数 gFCOpEvidence，从不参与任何 view 隐藏**；
//    FCApplyNativeRules 只匹配「用户点选规则」，而用户那 5 条全是业务文案（生活服务/
//    我的卡包…），订单页「百元券包限量1折」banner 从来就没进过隐藏流程。
//    v11：①内置关键词并入有效规则表，真正隐藏；②关键词按真机文案更新（限量1折、
//    5元立减券、69.9元抢、立即抢购、9.9洗衣、领福利…），H5 的 K 数组同步；
//    ③内置命中加严格尺寸闸门（高≤25%屏/宽≥120/子树文本≤14）防整页误伤；
//    ④恢复判定改用合并规则表，避免内置规则被当成「已删」而立刻恢复；
//    ⑤菜单加「关闭内置规则」逃生口；⑥浮标加「内N」计数供诊断。
//
//  v10 相对 v9（真机九次反馈：App 退出重开后隐藏失效）：
//    两个方向同时堵死——①数据丢失：规则 NSUserDefaults + Library/plist 双保险，互为兜底；
//    ②重开没重扫：监听 UIApplicationDidBecomeActive，前台激活延迟 0.6s 强制重扫+重注入
//      （冷启动时页面 view 全新、无隐藏标记，必须重建隐藏态）。浮标「规则N」供诊断。
//
//  v9：修隐藏元素跳动/失效真因（FCTextsOf 读不到 hidden view）+ 规则类型标记与左滑编辑删除。
//    ①修复隐藏「失效」真因：v7 的可逆判定对 hidden view 调 FCTextsOf 读文字，但
//      FCCollectText 见 hidden 直接 return → 读到空 → 每 0.3s 误判「规则已删」自动恢复显示。
//      v9 改为隐藏时把「命中的规则串」存 associatedObject，恢复判定改为查该规则是否还在规则表。
//    ②规则面板：每条规则左侧显示类型标签（文/ID/类/图，按 #/. /img: 前缀判定，配色区分），
//      左滑露出「编辑/删除」按钮，编辑聚焦输入框、删除移除该行；点空白/完成统一保存。
//
//  v8：点选浮标让位到顶部 + 点击自动识别并用红框文字标记选中元素。
//    ①点选时浮标盖住页面上方 banner，且「点浮标=取消」，导致那一条区域元素选不中 →
//      进入点选把浮标挪到顶部安全区(y=52)让开内容区，点选改为连续模式（点顶部浮标才退出）。
//    ②点击命中后画临时标记：红框覆盖元素 frame + 标签显示识别到的文字/class，2.5s 消失；
//      网页 JS 回传元素 rect(x,y,w,h)，原生用 convertRect:toView:nil。
//
//  v7：止血 class 规则泛化误伤整页 + 隐形菜单连锁循环点击。
//    根因：v6 点选无文字元素时把触点最深的 UILabel/UIImageView 等**系统通用类**存成 class 规则，
//         扫描用 substring 匹配 → 命中整页同类控件（浮标显示 原141），连 UIAlertController
//         弹窗内容也被隐藏 → 用户点浮标后菜单弹出但内容不可见，误以为没弹，继续点屏幕误触
//         「点选广告元素」这个隐形按钮进入 picking → 表现为「循环点击吃掉整页」。
//    修复：①系统通用类禁止入库 + 启动时自愈剔除历史危险 class 规则；②class 名改精确相等匹配；
//         ③扫描排除 UIAlertController/键盘/文字特效 window 与 view；④被隐藏 view 记标记，
//         规则删除后恢复 hidden=NO（隐藏可逆）；⑤菜单加「清空全部规则(恢复页面)」紧急入口；
//         ⑥picking 模式点浮标自身=取消，不再误拾取。
//
//  v6：修浮标边缘吸附几何 bug + 点选多特征（文案/alt/id/class/img）。
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
static CGRect FCDefaultBadgeFrame(void);
static void FCShowPickMark(CGRect screenRect, NSString *text);
static void FCPickModeEnter(void);
static void FCPickModeExit(void);
static void FCShowDiagnose(void);   // v14：页面结构诊断面板
static void FCAppendDiagText(NSString *s);

#pragma mark - H5 脚本模板

static NSString * const FCJSAdCardsTemplate =
@"(function(){var W=window;W.__fcadUserRules=%@;"
// v13：版本号——规则/词表热更新时必须重建 sweep（闭包里的 K 是旧词表，幂等 return 会让它永不更新）
"if(W.__fcadLoaded&&W.__fcadVer===17){if(W.__fcadSweep){W.__fcadSweep();}return;}"
"W.__fcadLoaded=1;W.__fcadVer=17;W.__fcadHits=0;"
"var K=['百元券包','100元寄件券包','寄件券包','限量1折','限量2折','限量7折','寄件省钱卡','查价领返现','换季洗羽绒','换季洗','洗护券','5元立减券','69.9元','马上抢','立即抢购','9.9洗衣','领福利','立省30','顺丰专享券包'];"
"function keys(e){var a=[];function add(s){if(s&&(''+s).length>=2&&a.indexOf(''+s)<0)a.push(''+s);}"
"add((e.innerText||e.textContent||'').trim());"
"if(e.getAttribute){add(e.getAttribute('alt'));add(e.getAttribute('aria-label'));"
"if(e.id)add('#'+e.id);"
"var c=e.className&&(''+e.className).trim().split(/\\s+/)[0];if(c)add('.'+c);"
"var src=e.getAttribute('src')||e.getAttribute('data-src');"
"if(src){var m=src.split('/').pop().split('?')[0];"
"if(m&&m.length>=4&&/\\.(png|jpg|jpeg|gif|webp)/i.test(m))add('img:'+m);}"
// v14：CSS 背景图（很多运营位用 background-image，img 标签抓不到）
"var bg=e.style&&e.style.backgroundImage?e.style.backgroundImage:'';"
"var bm=bg.match(/url\\(['\"]?([^'\")]+)/i);"
"if(bm){var bn=bm[1].split('/').pop().split('?')[0];if(bn&&bn.length>=4)add('img:'+bn);}}"
"return a;}"
"function hit(e){"
"if(!e||e.nodeType!==1)return false;"
"var t=(e.innerText||e.textContent||'').trim();if(t.length>160)return false;"
"var A=K.concat(W.__fcadUserRules||[]);var ks=keys(e);"
"for(var i=0;i<A.length;i++){var a=A[i];if(!a)continue;"
"if(a.charAt(0)==='#'){if(e.id&&e.id===a.slice(1))return true;continue;}"
"if(a.charAt(0)==='.'){if(e.className&&(''+e.className).split(/\\s+/).indexOf(a.slice(1))>=0)return true;continue;}"
"if(a.indexOf('img:')===0){var s=(e.getAttribute('src')||'')+' '+(e.getAttribute('data-src')||'');"
"if(s.indexOf(a.slice(4))>=0)return true;continue;}"
// v13：sel: 精确 CSS 选择器路径——图片型运营位无文字，靠结构指纹命中
"if(a.indexOf('sel:')===0){var q=a.slice(4);try{if(e.matches&&e.matches(q))return true;"
"if(e.querySelector&&e.querySelector(q))return true;}catch(ex){}continue;}"
"if(a.charAt(0)==='*'){var g=a.slice(1);if(g&&(t.indexOf(g)>=0))return true;"
"for(var z=0;z<ks.length;z++){if(ks[z].indexOf(g)>=0)return true;}continue;}"
"if(t&&t.indexOf(a)>=0)return true;"
"for(var j=0;j<ks.length;j++){if(ks[j].indexOf(a)>=0)return true;}}"
"return false;}"
"function sweep(){var all=document.querySelectorAll('div,li,a,section,article,img,span');"
"for(var i=0;i<all.length;i++){var e=all[i];if(!e||e.__fcadDone)continue;"
"if(!hit(e))continue;"
"var t=e;for(var k=0;k<2;k++){var p=t.parentElement;if(!p||p===document.body)break;"
"var pr=p.getBoundingClientRect();var tr=t.getBoundingClientRect();"
"if(tr.height>0&&pr.height<=tr.height*1.6&&pr.width<=window.innerWidth*0.96){t=p;}else{break;}}"
"var r=t.getBoundingClientRect();if(r.height>window.innerHeight*0.6){continue;}"
"t.style.setProperty('display','none','important');t.__fcadDone=1;W.__fcadHits=W.__fcadHits+1;}}"
"W.__fcadSweep=sweep;sweep();"
"if(document.documentElement&&!W.__fcadOb){W.__fcadOb=new MutationObserver(function(){sweep();});"
"W.__fcadOb.observe(document.documentElement,{childList:true,subtree:true});}})();";

static NSString * const FCPickJSFmt =
@"(function(){var e=document.elementFromPoint(%f,%f);if(!e)return 'MISS';"
"var out=[];function add(s){if(s&&(''+s).length>=2&&out.indexOf(''+s)<0)out.push(''+s);}"
"add((e.innerText||e.textContent||'').trim());"
"if(e.getAttribute){add(e.getAttribute('alt'));add(e.getAttribute('aria-label'));"
"if(e.id)add('#'+e.id);"
"var c=e.className&&(''+e.className).trim().split(/\\s+/)[0];if(c)add('.'+c);"
"var src=e.getAttribute('src')||e.getAttribute('data-src');"
"if(src){var m=src.split('/').pop().split('?')[0];"
"if(m&&m.length>=4&&/\\.(png|jpg|jpeg|gif|webp)/i.test(m))add('img:'+m);}}"
"var t=e;for(var k=0;k<3;k++){var p=t.parentElement;if(!p||p===document.body)break;"
"var pr=p.getBoundingClientRect();var tr=t.getBoundingClientRect();"
"if(tr.height>0&&pr.height<=tr.height*1.8&&pr.width<=window.innerWidth*0.97){t=p;}else{break;}}"
"var r=t.getBoundingClientRect();if(r.height>window.innerHeight*0.85)return 'TOOBIG';"
// v13：为容器生成 CSS 结构指纹——图片型广告无文字，靠路径记住它
"function cssel(el){var a=[];var p=el;for(var d=0;d<5&&p&&p.tagName&&p.tagName!=='BODY';d++){"
"var s=p.tagName.toLowerCase();"
"if(p.id){s+='#'+p.id;a.unshift(s);break;}"
"var cl=p.className&&(''+p.className).trim().split(/\\s+/)[0];if(cl)s+='.'+cl;"
"var par=p.parentElement,ix=1;if(par){var sib=par.children;for(var z=0;z<sib.length;z++){"
"if(sib[z]===p)break;if(sib[z].tagName===p.tagName)ix++;}}"
"if(ix>1)s+=':nth-of-type('+ix+')';a.unshift(s);p=p.parentElement;}"
"return a.join(' > ');}"
"var sel=cssel(t);if(sel&&sel.length>2)add('sel:'+sel);"
"t.style.setProperty('display','none','important');t.__fcadDone=1;"
// v8：回传元素位置(x,y,w,h)供原生画标记框，CSSError-free
"return Math.round(r.left)+','+Math.round(r.top)+','+Math.round(r.width)+','+Math.round(r.height)+'|'+out.join('|');})();";

#pragma mark - 用户规则持久化

static NSString * const FCUserRulesKey = @"FCAdBlockUserRules_v3";  // 保留 key，延续已存规则

// v10：规则双保险文件——注入环境下 NSUserDefaults 可能被宿主清理/迁移，额外落盘一份
static NSString *FCRulesFilePath(void) {
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject;
    return [dir stringByAppendingPathComponent:@"fcadblock_rules.plist"];
}

// v7：系统通用类黑名单——这些类作规则会命中整页控件，造成「页面被吃掉」
static BOOL FCIsUnsafeClassRule(NSString *rule) {
    if (rule.length < 2) return YES;
    if ([rule hasPrefix:@"#"] || [rule hasPrefix:@"."] || [rule hasPrefix:@"img:"] ||
        [rule hasPrefix:@"cls:"] || [rule hasPrefix:@"pos:"] || [rule hasPrefix:@"sel:"]) return NO;
    // 只把「首字母大写、纯字母」的串当作 class 规则来检查
    unichar h = [rule characterAtIndex:0];
    if (!(h >= 'A' && h <= 'Z')) return NO;
    BOOL allLetter = YES;
    for (NSUInteger i = 0; i < rule.length; i++) {
        unichar c = [rule characterAtIndex:i];
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z'))) { allLetter = NO; break; }
    }
    if (!allLetter) return NO;
    static NSArray *unsafe = nil; static dispatch_once_t once;
    dispatch_once(&once, ^{
        unsafe = @[@"UIView",@"UILabel",@"UIImageView",@"UIButton",@"UIControl",@"UICollectionViewCell",
                   @"UITableViewCell",@"UICollectionView",@"UITableView",@"UIStackView",@"UIScrollView",
                   @"UITextField",@"UITextView",@"UIViewController",@"UIAlertController",@"UIWindow",
                   @"Cell",@"View",@"Label",@"Image",@"Button",@"Stack",@"Content",@"Container",@"Wrapper"];
    });
    for (NSString *u in unsafe)
        if ([rule rangeOfString:u options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    // 系统 UI/NS 前缀一律不放行
    if ([rule hasPrefix:@"UI"] || [rule hasPrefix:@"NS"]) return YES;
    return NO;
}

static NSArray<NSString *> *FCUserRules(void) {
    NSArray *a = [[NSUserDefaults standardUserDefaults] arrayForKey:FCUserRulesKey];
    if (a.count) return a;                                                    // NSUserDefaults 优先
    NSArray *file = [NSArray arrayWithContentsOfFile:FCRulesFilePath()];      // v10：兜底读文件
    if (file.count) {
        [[NSUserDefaults standardUserDefaults] setObject:file forKey:FCUserRulesKey];  // 回填
        return file;
    }
    return @[];
}

// v7：启动自愈——把历史存下来的危险 class 规则剔除，避免老规则继续误伤
static void FCSanitizeRulesOnce(void) {
    NSArray *a = FCUserRules();
    if (!a.count) return;
    NSMutableArray *clean = [NSMutableArray array];
    for (NSString *s in a)
        if (!FCIsUnsafeClassRule(s)) [clean addObject:s];
    if (clean.count != a.count) {
        FCSetUserRules(clean);
        FCLog(@"自愈：剔除 %lu 条危险 class 规则，剩 %lu 条",
              (unsigned long)(a.count - clean.count), (unsigned long)clean.count);
    }
}

static void FCSetUserRules(NSArray *rules) {
    NSMutableArray *clean = [NSMutableArray array];
    for (NSString *s in rules) {
        NSString *v = FCJSSafe(s);
        if (v.length >= 2 && ![clean containsObject:v]) [clean addObject:v];
    }
    [[NSUserDefaults standardUserDefaults] setObject:clean forKey:FCUserRulesKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    // v10：双保险写文件（原子写），NSUserDefaults 被清时仍能恢复
    [clean writeToFile:FCRulesFilePath() atomically:YES];
}

static NSString *FCJSSafe(NSString *s) {
    s = [s stringByReplacingOccurrencesOfString:@"'" withString:@""];
    s = [s stringByReplacingOccurrencesOfString:@"\\" withString:@""];
    s = [s stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    s = [s stringByReplacingOccurrencesOfString:@"\r" withString:@" "];
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    // v13：指纹规则（sel: CSS 路径 / pos: 坐标）必须完整保留，截断就失效；改用更长上限
    NSUInteger cap = ([s hasPrefix:@"sel:"] || [s hasPrefix:@"pos:"] ||
                      [s hasPrefix:@"cls:"] || [s hasPrefix:@"img:"]) ? 160 : 40;
    if (s.length > cap) s = [s substringToIndex:cap];
    return s;
}

static void FCAddUserRule(NSString *raw) {
    NSString *rule = FCJSSafe(raw);
    if (rule.length < 2) return;
    if (FCIsUnsafeClassRule(rule)) { FCLog(@"拒绝危险 class 规则：%@", rule); return; }   // v7
    NSMutableArray *a = [NSMutableArray arrayWithArray:FCUserRules()];
    BOOL isFingerprint = [rule hasPrefix:@"sel:"] || [rule hasPrefix:@"cls:"] ||
                         [rule hasPrefix:@"pos:"] || [rule hasPrefix:@"img:"] ||
                         [rule hasPrefix:@"#"] || [rule hasPrefix:@"."];
    for (NSString *exist in a) {
        // v13：指纹类规则（不同位置/选择器只是数字或路径不同）必须精确去重，包含判断会误杀
        if (isFingerprint) { if ([exist isEqualToString:rule]) return; }
        else if ([exist rangeOfString:rule].location != NSNotFound ||
                 [rule rangeOfString:exist].location != NSNotFound) return;
    }
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
static NSUInteger gFCBuiltinHits = 0;   // v11：内置运营广告规则命中数（区别于用户点选规则）
static NSUInteger gFCBuiltinBlocked = 0; // v12：内置命中但被尺寸闸门拦下的次数（诊断用）

#pragma mark - 双向规则匹配（v5 修复返回失效核心）

static BOOL FCRuleMatchesText(NSString *rule, NSString *text) {
    if (rule.length < 3 || text.length < 2) return NO;   // 短规则/空文案不匹配，防误伤
    if ([text rangeOfString:rule].location != NSNotFound) return YES;       // 文案含完整规则
    if (text.length >= 3 && [rule rangeOfString:text].location != NSNotFound) return YES;  // 规则含文案（重建后文案变短）
    return NO;
}

// v13：原生元素指纹——cls:类名（精确）+ pos:x,y,w,h 屏幕比例（容差 3%）。图片型运营位无文字也能记住
static BOOL FCRuleMatchesFingerprint(NSString *rule, NSString *cls, CGRect rect, CGFloat sw, CGFloat sh) {
    if ([rule hasPrefix:@"cls:"]) {
        NSString *want = [rule substringFromIndex:4];
        return want.length >= 4 && [want isEqualToString:cls];   // v7 教训：class 必须精确相等
    }
    if ([rule hasPrefix:@"pos:"]) {
        NSArray *p = [[rule substringFromIndex:4] componentsSeparatedByString:@","];
        if (p.count != 4) return NO;
        CGFloat x = [p[0] doubleValue] * sw, y = [p[1] doubleValue] * sh;
        CGFloat w = [p[2] doubleValue] * sw, h = [p[3] doubleValue] * sh;
        CGFloat tx = 7, ty = 14;   // 容差 pt（top bar 高度浮动）
        return fabs(rect.origin.x - x) <= tx && fabs(rect.origin.y - y) <= ty &&
               fabs(rect.size.width - w) <= 20 && fabs(rect.size.height - h) <= 20;
    }
    return NO;
}

#pragma mark - v17：通用广告类型体系（丰巢真机实证 + 淘宝 10.56.10 静态实证）

// v17：插件标注的常见广告类型。目标是持续补充、跨 App 通用。
typedef NS_ENUM(NSUInteger, FCAdType) {
    FCAdTypeUnknown = 0,
    FCAdTypeSplash,        // 开屏广告
    FCAdTypeReward,        // 激励视频
    FCAdTypeInterstitial,  // 插屏广告
    FCAdTypeBanner,        // 横幅广告
    FCAdTypeFeed,          // 信息流广告
    FCAdTypeOperation,     // 原生运营位（服务端下发卡片）
    FCAdTypeAlliance,      // 联盟 / 广告 SDK
};

static NSString *FCAdTypeName(FCAdType t) {
    switch (t) {
        case FCAdTypeSplash:       return @"开屏";
        case FCAdTypeReward:       return @"激励";
        case FCAdTypeInterstitial: return @"插屏";
        case FCAdTypeBanner:       return @"横幅";
        case FCAdTypeFeed:         return @"信息流";
        case FCAdTypeOperation:    return @"运营位";
        case FCAdTypeAlliance:     return @"联盟";
        default:                   return @"其他";
    }
}

// v17：类名 → 广告类型 权威表。新 App 的广告类只需往这里加一行，
// 类型标注 / FCClassIsAd 判定 / 诊断输出 / 规则面板 全部自动生效。
// 丰巢类来自 v14 诊断实证；淘宝类来自 10.56.10 主二进制 17385 个 ObjC 类静态提取。
static NSDictionary<NSString *, NSNumber *> *FCAdTypeClassTable(void) {
    static NSDictionary *t = nil; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        // —— 丰巢 HiveConsumer（开屏 / 插屏 / 运营位）——
        d[@"FCSplashADSManager"] = @(FCAdTypeSplash);
        d[@"SplashAdManager"] = @(FCAdTypeSplash);
        d[@"SplashAdLibHandler"] = @(FCAdTypeSplash);
        d[@"NativeSplashAdView"] = @(FCAdTypeSplash);
        d[@"SplashAdBottomView"] = @(FCAdTypeSplash);
        d[@"SplashAdScreenShotManager"] = @(FCAdTypeSplash);
        d[@"CheckOutAlertInsertADViewController"] = @(FCAdTypeInterstitial);
        d[@"InterstScrAdLibTaku"] = @(FCAdTypeInterstitial);
        d[@"InterstScrAdLibUBIX"] = @(FCAdTypeInterstitial);
        d[@"OpenScrAdLibToBid"] = @(FCAdTypeInterstitial);
        d[@"OpenScrAdLibUBIX"] = @(FCAdTypeInterstitial);
        d[@"LifeServiceHomeADPopAlertView"] = @(FCAdTypeOperation);
        d[@"DSPHomeAdsAlertView"] = @(FCAdTypeOperation);
        d[@"SendOrderAdBannerView"] = @(FCAdTypeBanner);
        d[@"BoxMobilePickADBannerView"] = @(FCAdTypeBanner);
        d[@"BoxMobilePickADBannerLeftView"] = @(FCAdTypeBanner);
        d[@"BoxMobilePickADBannerTopView"] = @(FCAdTypeBanner);
        d[@"BoxMobilePickADBannerSuccessView"] = @(FCAdTypeBanner);
        d[@"CheckoutAdFeedBannerCell"] = @(FCAdTypeFeed);
        d[@"CheckoutAdFeedMixBannerCell"] = @(FCAdTypeFeed);
        d[@"CheckoutAdFeedSepBannerCell"] = @(FCAdTypeFeed);
        d[@"WashSOAdsView"] = @(FCAdTypeOperation);
        d[@"WashSOAdsSectionView"] = @(FCAdTypeOperation);
        d[@"LifeServiceDetailAdCell"] = @(FCAdTypeOperation);
        d[@"WashImportSendAdsCell"] = @(FCAdTypeOperation);
        d[@"CashDeskTakuADCell"] = @(FCAdTypeOperation);
        d[@"AdCenter"] = @(FCAdTypeAlliance);
        d[@"AdsHandle"] = @(FCAdTypeAlliance);
        d[@"AdsCNManager"] = @(FCAdTypeAlliance);
        // —— 淘宝 Taobao4iPhone 10.56.10（开屏）——
        d[@"SPSplashController"] = @(FCAdTypeSplash);
        d[@"SPSplashView"] = @(FCAdTypeSplash);
        d[@"SPSplashViewConfig"] = @(FCAdTypeSplash);
        d[@"SPSplashArchSelection"] = @(FCAdTypeSplash);
        d[@"TBBootImageSplashDO"] = @(FCAdTypeSplash);
        d[@"TBBootImageExtSplashDO"] = @(FCAdTypeSplash);
        d[@"TBBootImageSplashSubSectionDO"] = @(FCAdTypeSplash);
        d[@"TBBootImageExtSplashHelper"] = @(FCAdTypeSplash);
        d[@"TXSplashInteractView"] = @(FCAdTypeSplash);
        d[@"TXSplashLottilePopView"] = @(FCAdTypeSplash);
        d[@"TBHomeTabGuideSplashHandler"] = @(FCAdTypeSplash);
        d[@"TBSplashTransitionContext"] = @(FCAdTypeSplash);
        // —— 淘宝（激励视频）——
        d[@"TBRewardKit"] = @(FCAdTypeReward);
        d[@"TBRewardModel"] = @(FCAdTypeReward);
        d[@"TBRewardService"] = @(FCAdTypeReward);
        d[@"TBCashRewardModel"] = @(FCAdTypeReward);
        d[@"TBCashRewardService"] = @(FCAdTypeReward);
        // —— 淘宝（横幅）——
        d[@"TBTDBannerView"] = @(FCAdTypeBanner);
        d[@"TBTDBannerEngine"] = @(FCAdTypeBanner);
        d[@"TBTDBannerModel"] = @(FCAdTypeBanner);
        d[@"TBHBannerTracker"] = @(FCAdTypeBanner);
        // —— 淘宝（联盟 / 广告 SDK：阿里妈妈 + Munion + MMAdBiz）——
        d[@"AKTsAlimamaAdAbility"] = @(FCAdTypeAlliance);
        d[@"MunionAdParamUtil"] = @(FCAdTypeAlliance);
        d[@"MunionAdRequestMiddleware"] = @(FCAdTypeAlliance);
        d[@"MunionAdaptObj"] = @(FCAdTypeAlliance);
        d[@"MunionCpaBusiness"] = @(FCAdTypeAlliance);
        d[@"MunionTBSDKServer"] = @(FCAdTypeAlliance);
        d[@"MMAdBizOrange"] = @(FCAdTypeAlliance);
        t = d;
    });
    return t;
}

// v17：查类名对应的广告类型（精确 + 去命名空间前缀），供诊断/面板标注
static FCAdType FCAdTypeOfClass(NSString *cls) {
    if (!cls.length) return FCAdTypeUnknown;
    NSDictionary *tbl = FCAdTypeClassTable();
    NSNumber *n = tbl[cls];
    if (n) return (FCAdType)n.unsignedIntegerValue;
    NSRange dot = [cls rangeOfString:@"." options:NSBackwardsSearch];
    if (dot.location != NSNotFound) {
        n = tbl[[cls substringFromIndex:dot.location + 1]];
        if (n) return (FCAdType)n.unsignedIntegerValue;
    }
    return FCAdTypeUnknown;
}

#pragma mark - 类名 / 文案判定

static NSArray<NSString *> *FCAdClassKeys(void) {
    // v17：单一数据源——直接取权威表全部类名，新增类只需改 FCAdTypeClassTable 一处
    static NSArray *keys = nil; static dispatch_once_t once;
    dispatch_once(&once, ^{ keys = FCAdTypeClassTable().allKeys; });
    return keys;
}

// v17：通用强特征词根——跨 App 兜底（静态分析未覆盖的同类广告 SDK 也能命中）。
// Ad vs Adress 防护：命中前先排除地址业务（FCIsExcludedClass）。
static NSArray<NSString *> *FCAdGenericRoots(void) {
    static NSArray *roots = nil; static dispatch_once_t once;
    dispatch_once(&once, ^{ roots = @[
        @"splash",          // 开屏：SPSplash/TBBootImageSplash/TXSplash
        @"rewardkit", @"rewardservice", @"cashreward",  // 激励（激励业务词，谨慎）
        @"interstitial", @"interstscr", @"popupad", @"fullscreenad",  // 插屏
        @"munion", @"alimama", @"gromore", @"pangolin",  // 联盟/SDK
    ]; });
    return roots;
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
    // v17：先精确查权威表（去命名空间前缀）
    if (FCAdTypeOfClass(cls) != FCAdTypeUnknown) return YES;
    // v17：再通用词根兜底——必须排除 adress/address，且要求词根边界完整
    NSString *l = cls.lowercaseString;
    if ([l rangeOfString:@"adress"].location != NSNotFound ||
        [l rangeOfString:@"address"].location != NSNotFound) return NO;
    for (NSString *root in FCAdGenericRoots())
        if ([l rangeOfString:root].location != NSNotFound) return YES;
    return NO;
}

// v17：多宿主命名空间解析——丰巢 Swift 类在 HiveConsumer.*，淘宝宿主类在 Taobao4iPhone.*，
// ObjC 类/联盟 SDK 通常无前缀。逐个尝试，覆盖两个 App 及后续新增宿主。
static Class FCResolveClass(NSString *name) {
    if (!name.length) return nil;
    Class c = NSClassFromString(name);
    if (c) return c;
    static NSArray *prefixes = nil; static dispatch_once_t once;
    dispatch_once(&once, ^{ prefixes = @[
        @"HiveConsumer.",      // 丰巢 Swift 模块名
        @"Taobao4iPhone.",     // 淘宝宿主命名空间（若有）
    ]; });
    for (NSString *p in prefixes) {
        c = NSClassFromString([p stringByAppendingString:name]);
        if (c) return c;
    }
    return nil;
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

// v11：内置运营广告文案——真机反馈的 banner 实拍文案，必须真正参与隐藏，不能只做诊断计数
static NSArray<NSString *> *FCBuiltinAdKeys(void) {
    static NSArray *keys = nil; static dispatch_once_t once;
    dispatch_once(&once, ^{ keys = @[
        @"百元券包", @"100元寄件券包", @"寄件券包", @"限量1折",
        @"限量2折", @"限量7折", @"寄件省钱卡", @"查价领返现",
        @"换季洗羽绒", @"换季洗", @"洗护券", @"5元立减券",
        @"69.9元", @"马上抢", @"立即抢购", @"9.9洗衣",
        @"领福利", @"立省30", @"顺丰专享券包",
    ]; });
    return keys;
}

// v15：诊断实证的宿主运营组件类——原生卡片文字是「¥20/洗衣」等价格，文字词表永远匹配不上，
// 只能按类名隐藏。这些类来自真机诊断输出（HiveConsumer.PersonaMoreCouponItemView 等）。
static NSArray<NSString *> *FCBuiltinAdClasses(void) {
    static NSArray *keys = nil; static dispatch_once_t once;
    dispatch_once(&once, ^{ keys = @[
        @"PersonaMoreCouponItemView",    // 我的页-更多省钱卡列表项（¥20/洗衣）
    ]; });
    return keys;
}

static BOOL FCIsBuiltinAdKey(NSString *s) {
    if (!s.length) return NO;
    for (NSString *k in FCBuiltinAdKeys()) if ([k isEqualToString:s]) return YES;
    return NO;
}

// v11：内置规则总开关，误伤时可在菜单关闭（默认开）
static NSString * const FCBuiltinOffKey = @"FCAdBlockBuiltinOff_v1";
static BOOL FCBuiltinEnabled(void) {
    return ![[NSUserDefaults standardUserDefaults] boolForKey:FCBuiltinOffKey];
}

// v11：用户规则 + 内置运营广告规则 = 真正用于隐藏的有效规则表
static NSArray<NSString *> *FCEffectiveRules(void) {
    NSMutableArray *a = [NSMutableArray arrayWithArray:FCUserRules()];
    if (FCBuiltinEnabled()) [a addObjectsFromArray:FCBuiltinAdKeys()];
    return a;
}

static BOOL FCTextsAreOperationAd(NSArray<NSString *> *texts) {
    for (NSString *s in texts) for (NSString *k in FCBuiltinAdKeys())
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
    NSString *bestCN = nil, *bestASCII = nil;
    for (NSString *s in texts) {
        if (s.length < 2) continue;
        BOOL hasCN = NO;
        for (NSUInteger i = 0; i < s.length; i++) {
            unichar c = [s characterAtIndex:i];
            if (c >= 0x4e00 && c <= 0x9fff) { hasCN = YES; break; }
        }
        if (hasCN) {
            if (!bestCN || s.length > bestCN.length) bestCN = s;
        } else {
            // v6：无中文时收 ASCII 长串（≥4，且非纯数字/纯符号），覆盖英文/图标型广告
            if (s.length < 4) continue;
            BOOL hasLetter = NO, hasDigit = NO;
            for (NSUInteger i = 0; i < s.length; i++) {
                unichar c = [s characterAtIndex:i];
                if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) hasLetter = YES;
                else if (c >= '0' && c <= '9') hasDigit = YES;
            }
            if (hasLetter || hasDigit) {
                if (!bestASCII || s.length > bestASCII.length) bestASCII = s;
            }
        }
    }
    return bestCN ?: bestASCII;
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

// v16：塌陷移除记录——把命中的运营位从视图树摘掉，让下方元素自动补齐；规则删除时可插回
@interface FCFlattenRecord : NSObject
@property (nonatomic, strong) UIView *view;
@property (nonatomic, weak) UIView *superview;
@property (nonatomic, assign) NSUInteger index;
@property (nonatomic, copy) NSString *rule;
@end
@implementation FCFlattenRecord
@end
static NSMutableArray<FCFlattenRecord *> *gFCFlattened = nil;

// v16：检查已塌陷的 view——规则还在就保持移除，规则删了就插回原位（可逆）
static void FCRestoreFlattenedIfNeeded(NSArray<NSString *> *rules) {
    if (!gFCFlattened.count) return;
    NSMutableArray *gone = [NSMutableArray array];
    for (FCFlattenRecord *rec in gFCFlattened) {
        BOOL still = NO;
        for (NSString *r in rules) {
            if ([r isEqualToString:rec.rule] ||
                [r rangeOfString:rec.rule].location != NSNotFound ||
                [rec.rule rangeOfString:r].location != NSNotFound) { still = YES; break; }
        }
        if (!still || !rec.superview) [gone addObject:rec];
    }
    for (FCFlattenRecord *rec in gone) {
        if (rec.superview) {
            NSUInteger i = MIN(rec.index, rec.superview.subviews.count);
            [rec.superview insertSubview:rec.view atIndex:i];
            rec.view.hidden = NO;
            if ([rec.superview isKindOfClass:NSClassFromString(@"UIStackView")])
                [rec.superview setNeedsLayout];
        }
        [gFCFlattened removeObject:rec];
    }
}

static void FCApplyNativeRules(void) {
    NSArray *rules = FCEffectiveRules();   // v11：用户规则 + 内置运营广告关键词
    if (!gFCFlattened) gFCFlattened = [NSMutableArray array];
    FCRestoreFlattenedIfNeeded(rules);     // v16：规则删了的塌陷元素插回原位
    CGFloat sh = [UIScreen mainScreen].bounds.size.height;
    static char kHiddenByFC;
    for (UIWindow *w in FCAllWindows()) {
        NSString *wc = NSStringFromClass([w class]);
        if ([wc isEqualToString:@"FCBadgeWindow"] || [wc isEqualToString:@"FCPanelWindow"] || [wc isEqualToString:@"FCDiagWindow"]) continue;
        if (w.hidden || w.alpha < 0.01) continue;
        // v7：绝不扫描系统弹窗/键盘/文字特效 window，否则把 UIAlertController 内容也隐藏
        if ([wc hasPrefix:@"UITextEffects"] || [wc hasPrefix:@"UIRemoteKeyboard"] ||
            [wc hasPrefix:@"UIAlert"] || [wc hasPrefix:@"_UI"]) continue;
        UIViewController *wr = w.rootViewController;
        if ([wr isKindOfClass:[UIAlertController class]]) continue;
        NSMutableArray<UIView *> *q = [NSMutableArray arrayWithObject:w];
        NSUInteger idx = 0;
        while (idx < q.count && idx < 1400) {
            UIView *v = q[idx++];
            if (v.tag == 9527 || v.tag == 9528) continue;
            NSString *vcls = NSStringFromClass([v class]);
            // v7：遇到系统弹窗视图整枝跳过（不隐藏、不下钻）
            if ([v isKindOfClass:[UIAlertController class]] ||
                [vcls hasPrefix:@"UIAlert"] || [vcls hasPrefix:@"_UIAlert"]) continue;

            // v9：被本插件隐藏过的 view——只有「当初命中的规则已被删除」才恢复显示。
            // v7 旧做法(FCTextsOf重判)有致命 bug：hidden view 的文字根本读不到 → 每轮都误判失效→立刻恢复。
            id stored = objc_getAssociatedObject(v, &kHiddenByFC);
            if (stored && v.hidden) {
                NSString *ruleUsed = [stored isKindOfClass:[NSString class]] ? stored : nil;
                BOOL stillValid = NO;
                if (ruleUsed.length) {
                    for (NSString *r in rules) {
                        if ([r isEqualToString:ruleUsed] ||
                            [r rangeOfString:ruleUsed].location != NSNotFound ||
                            [ruleUsed rangeOfString:r].location != NSNotFound) { stillValid = YES; break; }
                    }
                }
                if (!stillValid) {
                    v.hidden = NO;
                    objc_setAssociatedObject(v, &kHiddenByFC, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
                // 命中规则仍在 → 保持隐藏，但继续下钻子视图
                for (UIView *sub in v.subviews) [q addObject:sub];
                continue;
            }

            CGRect r = [v convertRect:v.bounds toView:nil];
            if (v.hidden || r.size.width < 40 || r.size.height < 18 || r.size.height > sh * 0.5) {
                for (UIView *sub in v.subviews) [q addObject:sub];
                continue;
            }
            if ([vcls rangeOfString:@"TabBar"].location != NSNotFound ||
                [vcls rangeOfString:@"NavigationBar"].location != NSNotFound) {
                for (UIView *sub in v.subviews) [q addObject:sub];
                continue;
            }
            NSArray *texts = FCTextsOf(v);
            BOOL hit = NO;
            NSString *hitRule = nil;
            BOOL builtinHit = NO;
            BOOL classHardHit = NO;   // v15：类名硬证据命中，跳过文案闸门
            // v7：class 名改为「精确相等」匹配（子串匹配会让 Cell/Label 命中整页同类）
            for (NSString *rule in rules) {
                if (rule.length >= 5 && [rule isEqualToString:vcls]) { hit = YES; hitRule = rule; break; }
                // v13：元素指纹 cls:/pos:——图片型运营位（无文字）靠类名+屏幕位置命中
                if (FCRuleMatchesFingerprint(rule, vcls, r, [UIScreen mainScreen].bounds.size.width, sh)) {
                    hit = YES; hitRule = rule; break;
                }
            }
            // v15：内置运营组件类（诊断实证）——按类名精确命中，不受文案/闸门影响
            if (!hit && FCBuiltinEnabled()) {
                for (NSString *bc in FCBuiltinAdClasses()) {
                    if ([vcls rangeOfString:bc].location != NSNotFound) {
                        hit = YES; hitRule = bc; builtinHit = YES; classHardHit = YES; break;
                    }
                }
            }
            if (!hit) for (NSString *s in texts) {
                for (NSString *rule in rules) {
                    if (FCRuleMatchesText(rule, s)) {
                        hit = YES; hitRule = rule;
                        builtinHit = FCIsBuiltinAdKey(rule);
                        break;
                    }
                }
                if (hit) break;
            }
            if (hit) {
                // v11：内置关键词命中时加严格尺寸闸门——绝不让「包含 banner 的大卡片」整块消失
                if (builtinHit && !classHardHit && (r.size.height > sh * 0.30 || r.size.width < 90 || texts.count > 16)) {
                    gFCBuiltinBlocked++;   // v12：浮标可见，区分「没匹配」和「匹配但被闸门挡」
                    for (UIView *sub in v.subviews) [q addObject:sub];
                    continue;
                }
                gFCNativeHits++;
                if (builtinHit) gFCBuiltinHits++;
                // v16：塌陷移除——从父视图摘掉让下方元素补齐，不再留空占位。
                // 用记录表保住 view（否则释放），规则删除时 FCRestoreFlattenedIfNeeded 插回。
                // 只对「有 superview 的普通视图」塌陷；已记录过的跳过。
                BOOL alreadyFlattened = NO;
                for (FCFlattenRecord *rec in gFCFlattened) if (rec.view == v) { alreadyFlattened = YES; break; }
                if (v.superview && !alreadyFlattened) {
                    FCFlattenRecord *rec = [FCFlattenRecord new];
                    rec.view = v;
                    rec.superview = v.superview;
                    rec.index = [v.superview.subviews indexOfObject:v];
                    rec.rule = hitRule ?: @"";
                    [gFCFlattened addObject:rec];
                    [v removeFromSuperview];
                    // 父视图是 stack/collection 时触发布局重算，下方元素自动补齐
                    if ([v.superview isKindOfClass:NSClassFromString(@"UIStackView")] ||
                        [v.superview isKindOfClass:[UIScrollView class]]) [v.superview setNeedsLayout];
                } else {
                    v.hidden = YES;   // 兜底：无父视图时用隐藏
                    objc_setAssociatedObject(v, &kHiddenByFC, hitRule ?: @"", OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
            }
            for (UIView *sub in v.subviews) [q addObject:sub];
        }
    }
}

static void FCScanOnce(void) {
    NSArray *windows = FCAllWindows(); gFCWindows = windows.count;
    for (UIWindow *w in windows) {
        if (!w || w.hidden || w.alpha < 0.01) continue;
        NSString *wc = NSStringFromClass([w class]);
        if ([wc isEqualToString:@"FCBadgeWindow"] || [wc isEqualToString:@"FCPanelWindow"] || [wc isEqualToString:@"FCDiagWindow"]) continue;
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
        if ([wc isEqualToString:@"FCBadgeWindow"] || [wc isEqualToString:@"FCPanelWindow"] || [wc isEqualToString:@"FCDiagWindow"]) continue;
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
                        // v8：首段是元素位置 x,y,w,h（CSS 坐标），其后是特征；解析后画标记框
                        NSArray *parts = [txt componentsSeparatedByString:@"|"];
                        NSString *rectStr = parts.firstObject;
                        NSArray *xywh = [rectStr componentsSeparatedByString:@","];
                        if (xywh.count == 4) {
                            CGRect wr = CGRectMake([xywh[0] doubleValue], [xywh[1] doubleValue],
                                                   [xywh[2] doubleValue], [xywh[3] doubleValue]);
                            CGRect wf = [web convertRect:web.bounds toView:nil];   // web 在屏幕上的位置
                            CGRect sr = CGRectMake(wf.origin.x + wr.origin.x, wf.origin.y + wr.origin.y,
                                                   wr.size.width, wr.size.height);
                            NSString *nm = parts.count > 1 ? parts[1] : @"网页元素";
                            CGRect finalRect = sr; NSString *finalName = nm;
                            dispatch_async(dispatch_get_main_queue(), ^{
                                FCShowPickMark(finalRect, finalName);
                            });
                        }
                        // v6：其余段为多个特征（文案/alt/id/class/图片名），全部记为规则
                        NSUInteger added = 0;
                        for (NSUInteger i = 1; i < parts.count; i++) {
                            NSString *rule = [parts[i] stringByTrimmingCharactersInSet:
                                              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                            if (rule.length < 2) continue;
                            unichar h = [rule characterAtIndex:0];
                            if ((h == '#' || h == '.') && rule.length < 5) continue;
                            if ([rule hasPrefix:@"img:"] && rule.length < 8) continue;
                            FCAddUserRule(rule); added++;
                        }
                        dispatch_async(dispatch_get_main_queue(), ^{
                            FCInjectWebViews(NO);
                            FCShowBadgeMsg(added ? @"网页·已隐藏并记住" : @"网页·已隐藏");
                        });
                        return;
                    }
                }
                dispatch_async(dispatch_get_main_queue(), ^{ FCShowBadgeMsg(@"网页·未命中元素"); });
            });
    } else {
        UIView *card = FCCardContainerFrom(hit);
        NSString *ruleText = FCPickRuleText(card);
        // v8：先把选中元素框出来并标注识别到的内容（页面可见反馈）
        CGRect markRect = [card convertRect:card.bounds toView:nil];
        NSString *cls = NSStringFromClass([hit class]);
        NSString *show = ruleText.length ? ruleText : cls;
        FCShowPickMark(markRect, show);
        card.hidden = YES;
        gFCNativeHits++;
        if (ruleText.length >= 2) FCAddUserRule(ruleText);
        // v15 修复真 bug：v13 存的是 hit(UIImageView 等系统类，被 FCIsUnsafeClassRule 拒绝)，
        // 导致点选从来没存下有用的类名。改为从 card 沿祖先链收集所有「宿主自定义类」。
        // 诊断实证：运营位是 HiveConsumer.PersonaMoreCouponItemView 这种宿主类，文字是 ¥20/洗衣
        NSUInteger clsAdded = 0;
        UIView *curC = card;
        for (int depth = 0; curC && depth < 6; depth++) {
            NSString *c = NSStringFromClass([curC class]);
            // 只收宿主自定义类（含点号如 HiveConsumer.XxxView，或带业务前缀），排除系统 UI/NS
            BOOL hostClass = ([c rangeOfString:@"."].location != NSNotFound) ||
                (![c hasPrefix:@"UI"] && ![c hasPrefix:@"NS"] && ![c isEqualToString:@"UIView"]);
            if (hostClass && c.length >= 6 && !FCIsUnsafeClassRule(c)) {
                FCAddUserRule([@"cls:" stringByAppendingString:c]);
                clsAdded++;
            }
            curC = curC.superview;
        }
        CGSize scr = [UIScreen mainScreen].bounds.size;
        CGRect nr = [card convertRect:card.bounds toView:nil];
        if (nr.size.width >= 40 && nr.size.height >= 18) {
            FCAddUserRule([NSString stringWithFormat:@"pos:%.3f,%.3f,%.3f,%.3f",
                nr.origin.x/scr.width, nr.origin.y/scr.height,
                nr.size.width/scr.width, nr.size.height/scr.height]);
        }
        FCShowBadgeMsg([NSString stringWithFormat:@"原生·已记%lu类+位置", (unsigned long)clsAdded]);
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
        if ([wc isEqualToString:@"FCBadgeWindow"] || [wc isEqualToString:@"FCPanelWindow"] || [wc isEqualToString:@"FCDiagWindow"]) continue;
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

// v9：规则类型判定（按前缀），用于在面板里给每条规则打标签
// v17：cls:类名 若能解析出广告类型则显示类型中文（开屏/激励/横幅…），便于识别规则用途
static NSString *FCRuleTypeText(NSString *r) {
    if ([r hasPrefix:@"#"]) return @"ID";
    if ([r hasPrefix:@"."]) return @"类";
    if ([r hasPrefix:@"img:"] || [r hasPrefix:@"IMG:"]) return @"图";
    if ([r hasPrefix:@"sel:"]) return @"选";   // v13：CSS 结构指纹
    if ([r hasPrefix:@"cls:"]) {
        FCAdType at = FCAdTypeOfClass([r substringFromIndex:4]);
        return at != FCAdTypeUnknown ? FCAdTypeName(at) : @"位";
    }
    if ([r hasPrefix:@"pos:"]) return @"位";  // v13：原生位置指纹
    return @"文";
}
static UIColor *FCRuleTypeColor(NSString *r) {
    if ([r hasPrefix:@"#"]) return [UIColor colorWithRed:0.55 green:0.35 blue:0.85 alpha:1];
    if ([r hasPrefix:@"."]) return [UIColor colorWithRed:0.95 green:0.55 blue:0.15 alpha:1];
    if ([r hasPrefix:@"img:"] || [r hasPrefix:@"IMG:"]) return [UIColor colorWithRed:0.2 green:0.65 blue:0.35 alpha:1];
    if ([r hasPrefix:@"sel:"]) return [UIColor colorWithRed:0.85 green:0.25 blue:0.55 alpha:1];
    if ([r hasPrefix:@"cls:"] || [r hasPrefix:@"pos:"]) return [UIColor colorWithRed:0.15 green:0.55 blue:0.75 alpha:1];
    return [UIColor colorWithRed:0.42 green:0.48 blue:0.58 alpha:1];
}

// v9：规则行——左侧类型标签 + 可编辑文字，左滑露出「编辑/删除」
@interface FCRuleRow : UIView <UIGestureRecognizerDelegate>
@property (nonatomic, strong) UITextField *field;
@property (nonatomic, strong) UILabel *typeTag;
@property (nonatomic, strong) UIView *front;
- (instancetype)initWithRule:(NSString *)rule placeholder:(BOOL)ph frame:(CGRect)frame;
@end

@implementation FCRuleRow
- (instancetype)initWithRule:(NSString *)rule placeholder:(BOOL)ph frame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    CGFloat w = frame.size.width, h = frame.size.height;
    self.clipsToBounds = YES;
    self.backgroundColor = [UIColor clearColor];

    UIButton *editB = [UIButton buttonWithType:UIButtonTypeCustom];
    editB.frame = CGRectMake(w - 132, 3, 62, h - 6);
    [editB setTitle:@"编辑" forState:UIControlStateNormal];
    editB.titleLabel.font = [UIFont systemFontOfSize:12];
    editB.backgroundColor = [UIColor colorWithRed:0.2 green:0.55 blue:0.95 alpha:1];
    editB.layer.cornerRadius = 6;
    [editB addTarget:self action:@selector(fcEdit) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:editB];

    UIButton *delB = [UIButton buttonWithType:UIButtonTypeCustom];
    delB.frame = CGRectMake(w - 66, 3, 62, h - 6);
    [delB setTitle:@"删除" forState:UIControlStateNormal];
    delB.titleLabel.font = [UIFont systemFontOfSize:12];
    delB.backgroundColor = [UIColor colorWithRed:0.9 green:0.2 blue:0.2 alpha:1];
    delB.layer.cornerRadius = 6;
    [delB addTarget:self action:@selector(fcDelete) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:delB];

    UIView *front = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, h)];
    front.backgroundColor = [UIColor whiteColor];
    front.layer.cornerRadius = 6;
    front.layer.borderColor = [UIColor colorWithRed:0.85 green:0.85 blue:0.87 alpha:1].CGColor;
    front.layer.borderWidth = 0.5;

    UILabel *tag = [[UILabel alloc] initWithFrame:CGRectMake(6, (h - 18) / 2, 28, 18)];
    tag.font = [UIFont boldSystemFontOfSize:10];
    tag.textAlignment = NSTextAlignmentCenter;
    tag.textColor = [UIColor whiteColor];
    tag.layer.cornerRadius = 4; tag.clipsToBounds = YES;
    tag.text = ph ? @"＋" : FCRuleTypeText(rule);
    tag.backgroundColor = ph ? [UIColor lightGrayColor] : FCRuleTypeColor(rule);
    [front addSubview:tag];
    self.typeTag = tag;

    UITextField *f = [[UITextField alloc] initWithFrame:CGRectMake(40, 3, w - 46, h - 6)];
    f.text = ph ? nil : rule;
    f.placeholder = ph ? @"新增规则（广告文字）" : nil;
    f.font = [UIFont systemFontOfSize:12];
    f.clearButtonMode = UITextFieldViewModeWhileEditing;
    [f addTarget:self action:@selector(fcTextChanged) forControlEvents:UIControlEventEditingChanged];
    [front addSubview:f];
    self.field = f;

    UISwipeGestureRecognizer *sl = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(fcSwipe:)];
    sl.direction = UISwipeGestureRecognizerDirectionLeft; sl.delegate = self;
    [front addGestureRecognizer:sl];
    UISwipeGestureRecognizer *sr = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(fcSwipe:)];
    sr.direction = UISwipeGestureRecognizerDirectionRight; sr.delegate = self;
    [front addGestureRecognizer:sr];

    self.front = front;
    [self addSubview:front];
    return self;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)o { return YES; }
- (void)fcSwipe:(UISwipeGestureRecognizer *)g {
    [self endEditing:YES];
    CGFloat tx = (g.direction == UISwipeGestureRecognizerDirectionLeft) ? -136 : 0;
    [UIView animateWithDuration:0.2 animations:^{
        self.front.frame = CGRectMake(tx, 0, self.front.frame.size.width, self.front.frame.size.height);
    }];
}
- (void)fcEdit {
    [UIView animateWithDuration:0.2 animations:^{
        self.front.frame = CGRectMake(0, 0, self.front.frame.size.width, self.front.frame.size.height);
    }];
    [self.field becomeFirstResponder];
}
- (void)fcDelete { [self removeFromSuperview]; }
- (void)fcTextChanged {
    self.typeTag.text = FCRuleTypeText(self.field.text);
    self.typeTag.backgroundColor = FCRuleTypeColor(self.field.text);
}
@end

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
    title.text = @"已生效规则（左滑编辑/删除 · 点空白保存）";
    title.font = [UIFont boldSystemFontOfSize:14];
    title.textColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.12 alpha:1];
    [card addSubview:title];

    CGFloat rowY = 50;
    NSArray *rules = FCUserRules();
    for (NSUInteger i = 0; i < rules.count && rowY < cardH - 110; i++) {
        FCRuleRow *row = [[FCRuleRow alloc] initWithRule:rules[i] placeholder:NO
                                        frame:CGRectMake(12, rowY, w - 24, 36)];
        row.tag = 9528;   // 扫描排除
        [card addSubview:row];
        rowY += 42;
    }
    // 至少留一个空行方便新增
    if (rowY < cardH - 110) {
        FCRuleRow *row = [[FCRuleRow alloc] initWithRule:nil placeholder:YES
                                        frame:CGRectMake(12, rowY, w - 24, 36)];
        row.tag = 9528;
        [card addSubview:row];
        rowY += 42;
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

#pragma mark - v14：页面结构诊断面板（原生视图树 + WKWebView DOM）

@interface FCDiagWindow : UIWindow
- (void)fcCloseDiag;
@end
static FCDiagWindow *gFCDiagWindow = nil;
static UITextView *gFCDiagText = nil;

@implementation FCDiagWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (void)fcCloseDiag {
    [self.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    self.hidden = YES;
    gFCDiagText = nil;
}
@end

static void FCAppendDiagText(NSString *s) {
    if (!gFCDiagText) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        gFCDiagText.text = [gFCDiagText.text stringByAppendingFormat:@"%@\n", s];
        [gFCDiagText scrollRangeToVisible:NSMakeRange(gFCDiagText.text.length, 0)];
    });
}

// 异步收集：原生视图树 + 每个 WKWebView 的 DOM 摘要，全部写进诊断文本框
static void FCFillDiagnose(void) {
    FCAppendDiagText(@"===== FC 页面诊断 v17 =====");
    FCAppendDiagText([NSString stringWithFormat:@"顶层VC: %@", NSStringFromClass([FCTopViewController() class]) ?: @"-"]);
    FCAppendDiagText([NSString stringWithFormat:@"用户规则 %lu 条 / 内置命中 %lu / 被挡 %lu",
        (unsigned long)FCUserRules().count, (unsigned long)gFCBuiltinHits, (unsigned long)gFCBuiltinBlocked]);
    // 1) 原生视图树：列出所有有文字的 view（class + 文字 + frame），并标记它命中了哪条规则
    NSArray *rules = FCEffectiveRules();
    for (UIWindow *w in FCAllWindows()) {
        NSString *wc = NSStringFromClass([w class]);
        if ([wc isEqualToString:@"FCBadgeWindow"] || [wc isEqualToString:@"FCPanelWindow"] ||
            [wc isEqualToString:@"FCDiagWindow"]) continue;
        NSMutableArray<UIView *> *q = [NSMutableArray arrayWithObject:w];
        NSUInteger idx = 0;
        while (idx < q.count && idx < 400) {
            UIView *v = q[idx++];
            NSArray *texts = FCTextsOf(v);
            if (texts.count) {
                NSString *joined = [[texts subarrayWithRange:NSMakeRange(0, MIN(texts.count, 3))]
                                    componentsJoinedByString:@" / "];
                CGRect r = [v convertRect:v.bounds toView:nil];
                // 标出哪些规则命中了这个 view 的文字
                NSMutableArray *matched = [NSMutableArray array];
                for (NSString *rule in rules) {
                    for (NSString *t in texts) {
                        if (FCRuleMatchesText(rule, t)) { [matched addObject:rule]; break; }
                    }
                }
                // v17：类名命中权威表时标注广告类型（开屏/激励/横幅/运营位/联盟…）
                NSString *vcls = NSStringFromClass([v class]);
                FCAdType at = FCAdTypeOfClass(vcls);
                NSString *typeTag = (at != FCAdTypeUnknown)
                    ? [NSString stringWithFormat:@"[类型:%@]", FCAdTypeName(at)] : @"";
                FCAppendDiagText([NSString stringWithFormat:@"[原生]%@ %@ | %@ | %.0f,%.0f %.0fx%.0f | 命中:%@",
                    typeTag, vcls, joined,
                    r.origin.x, r.origin.y, r.size.width, r.size.height,
                    matched.count ? [matched componentsJoinedByString:@","] : @"无"]);
            }
            for (UIView *sub in v.subviews) [q addObject:sub];
        }
    }
    // 2) WKWebView：注入诊断 JS，回传 body 直系运营文案 + 图片名 + 数量
    Class wk = NSClassFromString(@"WKWebView"); if (!wk) { FCAppendDiagText(@"无 WKWebView 类"); return; }
    SEL sel = NSSelectorFromString(@"evaluateJavaScript:completionHandler:");
    NSString *js = @"(function(){var a=document.querySelectorAll('div,li,a,section,article,img,span,p');"
        "var out=[],n=0;for(var i=0;i<a.length&&n<25;i++){var e=a[i];"
        "var t=(e.innerText||e.textContent||'').trim();"
        "var src=e.getAttribute('src')||e.getAttribute('data-src')||'';"
        "var bg=(e.style&&e.style.backgroundImage||'');"
        "if((t&&t.length>=2&&t.length<=60)||src||bg){out.push(e.tagName+'.'+(''+e.className).split(/\\s+/)[0]+' | '+t.slice(0,40)+' | '+src.split('/').pop().slice(0,30)+' | '+bg.slice(0,40));n++;}}"
        "return out.join('\\n')||'(DOM空)';})()";
    __block NSUInteger found = 0;
    for (UIWindow *w in FCAllWindows()) {
        NSMutableArray<UIView *> *q = [NSMutableArray arrayWithObject:w]; NSUInteger idx = 0;
        while (idx < q.count && idx < 400) {
            UIView *v = q[idx++];
            if ([v isKindOfClass:wk] && [v respondsToSelector:sel]) {
                found++;
                CGRect r = [v convertRect:v.bounds toView:nil];
                FCAppendDiagText([NSString stringWithFormat:@"----- WKWebView #%lu frame %.0f,%.0f %.0fx%.0f -----",
                    (unsigned long)found, r.origin.x, r.origin.y, r.size.width, r.size.height]);
                IMP imp = [v methodForSelector:sel];
                ((void (*)(id, SEL, NSString *, void (^)(id, NSError *)))imp)
                    (v, sel, js, ^(id result, NSError *err){
                        NSString *txt = err ? [NSString stringWithFormat:@"JS错误:%@", err.localizedDescription]
                                            : ([result isKindOfClass:[NSString class]] ? result : @"(无返回)");
                        for (NSString *line in [txt componentsSeparatedByString:@"\n"])
                            FCAppendDiagText([@"[网页] " stringByAppendingString:line]);
                    });
            }
            for (UIView *sub in v.subviews) [q addObject:sub];
        }
    }
    if (!found) FCAppendDiagText(@"未找到 WKWebView——运营位大概率是原生绘制");
    FCAppendDiagText(@"===== 诊断结束（可截图发我）=====");
}

static void FCShowDiagnose(void) {
    FCHidePanel();
    CGRect s = [UIScreen mainScreen].bounds;
    if (!gFCDiagWindow) {
        gFCDiagWindow = [[FCDiagWindow alloc] initWithFrame:s];
        gFCDiagWindow.windowLevel = UIWindowLevelAlert + 110;
        if (@available(iOS 13.0, *)) {
            for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
                if ([sc isKindOfClass:[UIWindowScene class]]) {
                    gFCDiagWindow.windowScene = (UIWindowScene *)sc; break;
                }
            }
        }
    }
    [gFCDiagWindow.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    gFCDiagWindow.frame = s;
    UIView *bg = [[UIView alloc] initWithFrame:s];
    bg.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.96];
    [gFCDiagWindow addSubview:bg];

    CGFloat top = 54;
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 18, s.size.width - 110, 30)];
    title.text = @"页面诊断（上滑查看）";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:16];
    [bg addSubview:title];
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(s.size.width - 90, 16, 76, 34);
    [close setTitle:@"关闭" forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:15];
    [close addTarget:gFCDiagWindow action:@selector(fcCloseDiag) forControlEvents:UIControlEventTouchUpInside];
    [bg addSubview:close];

    gFCDiagText = [[UITextView alloc] initWithFrame:CGRectMake(12, top, s.size.width - 24, s.size.height - top - 20)];
    gFCDiagText.backgroundColor = [UIColor clearColor];
    gFCDiagText.textColor = [UIColor colorWithRed:0.6 green:1.0 blue:0.7 alpha:1];
    gFCDiagText.font = [UIFont fontWithName:@"Menlo" size:10];
    gFCDiagText.editable = NO;
    gFCDiagText.text = @"收集页面中…";
    [bg addSubview:gFCDiagText];
    gFCDiagWindow.hidden = NO;
    [gFCDiagWindow makeKeyWindow];
    dispatch_async(dispatch_get_main_queue(), ^{ FCFillDiagnose(); });
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
static CGRect gFCBadgeNormalFrame = {0};   // v6：记住展开态的自由位置，供展开恢复
static FCBadgeWindow *gFCBadgeWindow = nil;
static BOOL gFCBadgeCollapsed = NO;      // 是否为吸附小白条
static NSInteger gFCBadgeSide = 0;       // 吸附边：0 左 / 1 右
static CGPoint gFCTouchStart = {0};
static BOOL gFCDidDrag = NO;

static CGRect FCDefaultBadgeFrame(void) {
    CGRect s = [UIScreen mainScreen].bounds;
    CGFloat w = MIN(s.size.width - 40, 250);   // v6：收窄胶囊，留出拖动空间
    return CGRectMake((s.size.width - w) / 2, 108, w, 40);
}

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
    if (!gFCBadgeCollapsed) gFCBadgeNormalFrame = f;   // v6：记住展开态自由位置
    gFCBadgeBar.frame = f;
    gFCTouchStart = p;
    if (gFCBadgeCollapsed) { gFCBadgeCollapsed = NO; [self expandBadgeFrame]; }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *t = [touches anyObject]; if (!t) return;
    CGPoint p = [t locationInView:self];

    if (self.picking) {                                   // 点选模式：拾取
        // v8：点顶部浮标自身=退出点选；否则拾取触点下的元素（浮标已让位到顶部，不挡内容区）
        if (CGRectContainsPoint(gFCBadgeFrame, p)) {
            FCPickModeExit();
            FCShowBadgeMsg(@"已结束选取");
            return;
        }
        // v8：保持点选模式（浮标在顶部让位），可连续选取多个元素；点顶部浮标才退出
        FCPickAtPoint(p);
        return;
    }
    if (gFCDidDrag) {                                     // 拖动结束：按「浮标边缘到屏幕边的距离」判定吸附
        CGRect s = self.bounds;
        CGRect f = gFCBadgeFrame;
        CGFloat leftGap = CGRectGetMinX(f);               // v6：不再用中心点（浮标宽时中心恒在中屏，永不贴边）
        CGFloat rightGap = s.size.width - CGRectGetMaxX(f);
        CGFloat snap = 44;                                // 距屏幕边 44pt 内即吸附
        if (leftGap <= snap) { gFCBadgeSide = 0; [self collapseToEdge]; }
        else if (rightGap <= snap) { gFCBadgeSide = 1; [self collapseToEdge]; }
        else { gFCBadgeCollapsed = NO; gFCBadgeNormalFrame = f; }
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
    CGFloat w = MIN(s.size.width - 40, 250);   // v6：收窄胶囊
    CGFloat h = 40;
    // v6：优先恢复到用户拖到的自由位置，否则按吸附边展开，再否则默认中上
    CGRect base = CGRectIsEmpty(gFCBadgeNormalFrame) ? FCDefaultBadgeFrame() : gFCBadgeNormalFrame;
    CGFloat x = base.origin.x, y = base.origin.y;
    x = MAX(0, MIN(x, s.size.width - w));
    y = MIN(MAX(y, 60), s.size.height - h - 40);
    gFCBadgeFrame = CGRectMake(x, y, w, h);
    gFCBadgeNormalFrame = gFCBadgeFrame;
    gFCBadgeBar.frame = gFCBadgeFrame;
    gFCBadgeLabel.frame = CGRectInset(gFCBadgeBar.bounds, 6, 2);
}

- (void)collapseToEdge {
    CGRect s = self.bounds;
    CGFloat w = 20, h = 64;                    // v6：加宽小白条，便于点按展开
    CGFloat x = gFCBadgeSide == 1 ? (s.size.width - w) : 0;
    CGFloat y = MIN(MAX(CGRectGetMidY(gFCBadgeFrame) - h / 2, 120), s.size.height - h - 100);
    if (!gFCBadgeCollapsed && !CGRectIsEmpty(gFCBadgeFrame)) gFCBadgeNormalFrame = gFCBadgeFrame;
    gFCBadgeCollapsed = YES;
    gFCBadgeFrame = CGRectMake(x, y, w, h);
    gFCBadgeBar.frame = gFCBadgeFrame;
    gFCBadgeLabel.frame = gFCBadgeBar.bounds;
    gFCBadgeLabel.text = @"⋮";
    gFCBadgeBar.backgroundColor = [[UIColor colorWithRed:0.2 green:0.5 blue:0.9 alpha:0.8] colorWithAlphaComponent:0.9];
}

@end

// v8：进入点选——把浮标挪到屏幕顶部让开内容区（浮标原本会盖住上方 banner，导致那一条选不中）
static CGRect gFCBadgeFrameBeforePick = {0};
static void FCPickModeEnter(void) {
    if (!gFCBadgeWindow) return;
    gFCBadgeFrameBeforePick = gFCBadgeFrame;
    gFCBadgeCollapsed = NO;
    CGRect s = gFCBadgeWindow.bounds;
    CGFloat w = MIN(s.size.width - 40, 200), h = 30;
    gFCBadgeFrame = CGRectMake((s.size.width - w) / 2, 52, w, h);   // 顶部安全区，避开运营 banner
    gFCBadgeBar.frame = gFCBadgeFrame;
    gFCBadgeLabel.frame = CGRectInset(gFCBadgeBar.bounds, 6, 2);
    gFCBadgeWindow.picking = YES;
    gFCBadgeLabel.text = @"点广告元素 · 点此结束选取";
    gFCBadgeBar.backgroundColor = [[UIColor colorWithRed:0.85 green:0.1 blue:0.1 alpha:0.9] colorWithAlphaComponent:0.9];
}

static void FCPickModeExit(void) {
    if (!gFCBadgeWindow) return;
    gFCBadgeWindow.picking = NO;
    // 清掉可能残留的标记
    for (UIView *v in [gFCBadgeWindow.subviews copy]) if (v.tag == 9529) [v removeFromSuperview];
    // 恢复进入点选前的浮标位置
    if (!CGRectIsEmpty(gFCBadgeFrameBeforePick)) {
        gFCBadgeFrame = gFCBadgeFrameBeforePick;
        gFCBadgeNormalFrame = gFCBadgeFrameBeforePick;
        gFCBadgeBar.frame = gFCBadgeFrame;
        gFCBadgeLabel.frame = CGRectInset(gFCBadgeBar.bounds, 6, 2);
    }
    FCUpdateBadge();
}

// v8：点选标记浮层——红框 + 识别文字，2.5s 自动消失（放在 gFCBadgeWindow 定义之后）
static void FCShowPickMark(CGRect screenRect, NSString *text) {
    if (!gFCBadgeWindow) return;
    for (UIView *old in [gFCBadgeWindow.subviews copy])
        if (old.tag == 9529) [old removeFromSuperview];

    CGRect s = gFCBadgeWindow.bounds;
    CGRect r = CGRectIntersection(screenRect, s);
    if (CGRectIsNull(r) || r.size.width < 1 || r.size.height < 1) return;

    UIView *mark = [[UIView alloc] initWithFrame:r];
    mark.tag = 9529;
    mark.userInteractionEnabled = NO;
    mark.backgroundColor = [[UIColor redColor] colorWithAlphaComponent:0.12];
    mark.layer.borderColor = [[UIColor colorWithRed:1 green:0.15 blue:0.15 alpha:1] CGColor];
    mark.layer.borderWidth = 2.0;
    mark.layer.cornerRadius = 4;
    [gFCBadgeWindow addSubview:mark];

    NSString *label = text.length ? [text stringByReplacingOccurrencesOfString:@"\n" withString:@" "] : @"(未识别到文字)";
    if (label.length > 22) label = [NSString stringWithFormat:@"%@…", [label substringToIndex:22]];
    UILabel *tip = [[UILabel alloc] init];
    tip.text = [@"已选中: " stringByAppendingString:label];
    tip.font = [UIFont boldSystemFontOfSize:11];
    tip.textColor = [UIColor whiteColor];
    tip.backgroundColor = [[UIColor colorWithRed:0.85 green:0.1 blue:0.1 alpha:0.95] colorWithAlphaComponent:0.95];
    tip.textAlignment = NSTextAlignmentCenter;
    tip.layer.cornerRadius = 4; tip.clipsToBounds = YES;
    CGFloat tw = MIN(s.size.width - 16, MAX(140, label.length * 13));
    CGFloat th = 24;
    CGFloat ty = CGRectGetMinY(r) - th - 2;
    if (ty < 50) ty = CGRectGetMaxY(r) + 2;
    if (ty + th > s.size.height - 10) ty = CGRectGetMinY(r) + 2;
    tip.frame = CGRectMake(MAX(8, CGRectGetMidX(r) - tw / 2), ty, tw, th);
    tip.tag = 9529;
    [gFCBadgeWindow addSubview:tip];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [mark removeFromSuperview];
        [tip removeFromSuperview];
    });
}

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
    gFCBadgeFrame = FCDefaultBadgeFrame();
    gFCBadgeNormalFrame = gFCBadgeFrame;
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
        @"FCv17 规则%lu 内%lu 挡%lu 原%lu H5%lu | 点我操作 | %@",
        (unsigned long)FCUserRules().count, (unsigned long)gFCBuiltinHits,
        (unsigned long)gFCBuiltinBlocked, (unsigned long)gFCNativeHits,
        (unsigned long)gFCH5Hits, top];
    gFCBadgeBar.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
}

static void FCShowBadgeMsg(NSString *msg) {
    if (!gFCBadgeLabel) return;
    if (gFCBadgeCollapsed) {
        gFCBadgeCollapsed = NO;
        [gFCBadgeWindow expandBadgeFrame];
    }
    gFCBadgeLabel.text = [@"FCv17 " stringByAppendingString:msg];
    gFCBadgeBar.backgroundColor = [[UIColor colorWithRed:0.1 green:0.5 blue:0.2 alpha:0.85] colorWithAlphaComponent:0.85];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ FCUpdateBadge(); });
}

// 操作菜单：用系统 UIAlertController（present 到顶层 VC），避免自绘触摸冲突
static void FCShowActionMenu(void) {
    UIViewController *top = FCTopViewController();
    if (!top) { FCShowBadgeMsg(@"无顶层页面"); return; }
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"FCAdBlock v17"
                              message:@"选择操作" preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"点选广告元素" style:UIAlertActionStyleDefault
                 handler:^(UIAlertAction *a){ FCPickModeEnter(); }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"管理规则（查看/编辑/新增）" style:UIAlertActionStyleDefault
                 handler:^(UIAlertAction *a){ FCShowRulePanel(); }]];
    // v14：诊断当前页面——一次看清运营位在原生还是网页、命中了什么规则
    [ac addAction:[UIAlertAction actionWithTitle:@"诊断当前页面（发给开发者）" style:UIAlertActionStyleDefault
                 handler:^(UIAlertAction *a){ FCShowDiagnose(); }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"浮标复位" style:UIAlertActionStyleDefault
                 handler:^(UIAlertAction *a){ gFCBadgeCollapsed = NO; gFCBadgeSide = 0;
                     gFCBadgeNormalFrame = FCDefaultBadgeFrame();
                     [gFCBadgeWindow expandBadgeFrame]; FCUpdateBadge(); }]];
    // v11：内置运营位规则总开关——原生视图被误伤时的逃生口
    [ac addAction:[UIAlertAction actionWithTitle:FCBuiltinEnabled() ? @"关闭内置运营位规则" : @"开启内置运营位规则"
                 style:UIAlertActionStyleDefault
                 handler:^(UIAlertAction *a){
                     BOOL wasOn = FCBuiltinEnabled();
                     [[NSUserDefaults standardUserDefaults] setBool:wasOn forKey:FCBuiltinOffKey];
                     [[NSUserDefaults standardUserDefaults] synchronize];
                     FCShowBadgeMsg(wasOn ? @"内置规则已关闭" : @"内置规则已开启");
                 }]];
    // v7：一键清空全部规则——页面被误伤时的紧急恢复入口
    [ac addAction:[UIAlertAction actionWithTitle:@"清空全部规则（恢复页面）" style:UIAlertActionStyleDestructive
                 handler:^(UIAlertAction *a){
                     FCSetUserRules(@[]);
                     FCInjectWebViews(YES);
                     FCShowBadgeMsg(@"已清空规则");
                 }]];
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
        // v17：淘宝 10.56.10 源头拦截——开屏/激励/联盟 SDK 的展示与请求入口
        @[@"SPSplashController",          @[@"show",@"start",@"load",@"showSplash"]],
        @[@"SPSplashView",                @[@"show",@"start",@"load"]],
        @[@"TBSplashTransitionContext",   @[@"show",@"start"]],
        @[@"TBRewardService",             @[@"show",@"load",@"requestReward"]],
        @[@"TBCashRewardService",         @[@"show",@"load",@"requestReward"]],
        @[@"MunionAdRequestMiddleware",   @[@"request",@"load",@"start"]],
        @[@"AKTsAlimamaAdAbility",        @[@"show",@"load",@"request"]],
    ];
    for (NSArray *row in table) FCSwizzleOwnMethods(row[0], row[1]);
}
#endif

#pragma mark - 入口

__attribute__((constructor))
static void FCAdBlockInit(void) {
    @autoreleasepool {
        FCLog(@"v17 载入，Bundle=%@", [[NSBundle mainBundle] bundleIdentifier]);
        gFCAttempts = [NSMapTable weakToStrongObjectsMapTable];
        FCSanitizeRulesOnce();   // v7：启动即清理历史危险 class 规则，救回被误伤的页面
        dispatch_async(dispatch_get_main_queue(), ^{
            FCEnsureBadgeWindow();
            // v16：加载后自动吸附右边缘收成小白条，不遮挡页面（点小白条仍可展开操作）
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (!gFCBadgeCollapsed && !gFCBadgeWindow.picking) {
                    gFCBadgeSide = 1;
                    [gFCBadgeWindow collapseToEdge];
                    FCLog(@"浮标已自动吸附右边缘");
                }
            });
            // v10：App 从后台回前台/冷启动激活时，页面是新建 view，强制重扫+重注入，恢复隐藏
            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n){
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    FCScanOnce();
                    FCApplyNativeRules();
                    FCInjectWebViews(YES);
                    FCUpdateBadge();
                    FCLog(@"前台激活：强制重扫完成，规则 %lu 条", (unsigned long)FCUserRules().count);
                });
            }];
            // v16：修「进页面闪一下才消失」——fast 从 8 秒(80次)延到 120 秒(1200次)，
            // slow 从 0.30s→0.12s；页面切换通知立即补扫，把可见窗口压到 ≈0.1s。
            __block NSInteger fastTicks = 0;
            NSTimer *fast = [NSTimer scheduledTimerWithTimeInterval:0.08 repeats:YES
                              block:^(NSTimer *t){ FCScanOnce(); if (++fastTicks > 1200) [t invalidate]; }];
            [[NSRunLoop mainRunLoop] addTimer:fast forMode:NSRunLoopCommonModes];
            __block NSInteger slowTicks = 0;
            NSTimer *slow = [NSTimer scheduledTimerWithTimeInterval:0.12 repeats:YES
                              block:^(NSTimer *t){
                FCScanOnce();
                if (++slowTicks % 8 == 0) FCInjectWebViews(NO);
                FCUpdateBadge();
            }];
            [[NSRunLoop mainRunLoop] addTimer:slow forMode:NSRunLoopCommonModes];
            // v16：页面 push/pop/tab 切换后立即重扫（视图刚创建是最容易闪现的时刻）
            [[NSNotificationCenter defaultCenter] addObserverForName:@"UINavigationControllerDidShowViewControllerNotification"
                object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n){
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ FCScanOnce(); });
            }];
            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillEnterForegroundNotification
                object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n){
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ FCScanOnce(); });
            }];
#ifdef FC_DEEP_HOOKS
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ FCInstallDeepHooks(); });
#endif
        });
    }
}

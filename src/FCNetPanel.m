//
//  FCNetPanel.m —— 网络抓包分析面板（v52）
//
//  UI 结构（单窗口、两级视图，不引入导航栈，避免和宿主 App 的导航打架）：
//    ┌ 顶部条：关闭 | 采集开关 | 清空 | 规则 | 复制全部
//    ├ 搜索框：按 方法/域名/路径/状态码 过滤
//    ├ 列表：每条一行（方法 host/path，右侧状态/大小/耗时）
//    └ 详情：点开覆盖列表，分段显示 请求头/请求体/响应头/响应体
//
#import "FCNet.h"

static UIWindow *gNetWin = nil;
static id gNetVC = nil;

#pragma mark - v56：配色与报告着色

// 一套颜色就够，不再散落在各处手写 RGB。
static UIColor *FCInk(void)    { return [UIColor colorWithRed:0.11 green:0.12 blue:0.15 alpha:1]; }
static UIColor *FCMuted(void)  { return [UIColor colorWithRed:0.56 green:0.58 blue:0.63 alpha:1]; }
static UIColor *FCDeep(void)   { return [UIColor colorWithRed:0.16 green:0.26 blue:0.44 alpha:1]; }
static UIColor *FCRed(void)    { return [UIColor colorWithRed:0.85 green:0.20 blue:0.16 alpha:1]; }
static UIColor *FCOrange(void) { return [UIColor colorWithRed:0.86 green:0.45 blue:0.08 alpha:1]; }
static UIColor *FCGreen(void)  { return [UIColor colorWithRed:0.13 green:0.56 blue:0.31 alpha:1]; }
static UIColor *FCBg(void)     { return [UIColor colorWithRed:0.95 green:0.955 blue:0.97 alpha:1]; }
static UIColor *FCLine(void)   { return [UIColor colorWithRed:0.89 green:0.90 blue:0.92 alpha:1]; }
static UIColor *FCBlue(void)   { return [UIColor colorWithRed:0.13 green:0.45 blue:0.85 alpha:1]; }

// 报告原来是一整块纯文本，所有行一个颜色——老大要「可疑的数据用红色标记」。
// 这里按行判定轻重：小节标题深蓝加粗，可疑项整行红，可执行动作橙，正常/无分项灰。
// 判定只看行首特征和关键词，不解析语义——报告格式是本文件自己产的，稳定可控。
static NSAttributedString *FCNetReportAttr(NSString *text) {
    NSMutableAttributedString *out = [NSMutableAttributedString new];
    if (!text.length) return out;

    UIFont *base  = [UIFont systemFontOfSize:11.5];
    UIFont *mono  = [UIFont fontWithName:@"Menlo" size:10.5] ?: base;
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.lineSpacing = 2.5;
    ps.paragraphSpacing = 1.0;

    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
    for (NSString *line in lines) {
        UIFont *f = base;
        UIColor *col = FCInk;
        NSString *trim = [line stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceCharacterSet]];

        if ([trim hasPrefix:@"▍"]) {                       // 小节标题
            f = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
            col = FCDeep;
        } else if ([trim hasPrefix:@"↳"]) {                // 原因 / 可改
            col = FCOrange;
        } else if ([trim containsString:@"★"] || [trim containsString:@"判定："] ||
                   [trim containsString:@"很可能是广告"]) {
            col = FCRed;                                    // 广告特征命中
            f = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        } else if ([trim hasPrefix:@"✓"]) {
            col = FCGreen;
        } else if ([trim containsString:@"·可疑"]) {       // 低分但仍带广告词
            col = FCOrange;
        } else if ([trim hasPrefix:@"http"] || [trim hasPrefix:@"GET "] ||
                   [trim hasPrefix:@"POST "] || [trim hasPrefix:@"PUT "] ||
                   [trim hasPrefix:@"DELETE "]) {           // 接口地址
            f = mono;
            col = [UIColor colorWithRed:0.30 green:0.38 blue:0.52 alpha:1];
        } else if ([trim containsString:@"×"]) {
            // 「9分 ×4  url」可疑条目 / 「  9 ×4   host/path」排行行
            NSScanner *sc = [NSScanner scannerWithString:trim];
            NSInteger score = 0;
            if ([sc scanInteger:&score]) {
                if (score >= 3)      { col = FCRed; }
                else if (score > 0)  { col = FCOrange; }
                else                 { col = FCMuted; }
            }
        } else if ([trim hasPrefix:@"⚠"]) {
            col = FCOrange;
        }

        NSString *body = line.length ? line : @" ";
        [out appendAttributedString:[[NSAttributedString alloc]
            initWithString:body
                attributes:@{NSFontAttributeName: f,
                             NSForegroundColorAttributeName: col,
                             NSParagraphStyleAttributeName: ps}]];
        [out appendAttributedString:[[NSAttributedString alloc]
            initWithString:@"\n" attributes:@{NSParagraphStyleAttributeName: ps}]];
    }
    return out;
}

#pragma mark - 格式化工具

static NSString *FCNetSizeText(NSUInteger n) {
    if (n < 1024) return [NSString stringWithFormat:@"%luB", (unsigned long)n];
    if (n < 1024 * 1024) return [NSString stringWithFormat:@"%.1fKB", n / 1024.0];
    return [NSString stringWithFormat:@"%.1fMB", n / 1024.0 / 1024.0];
}

static NSString *FCNetHeadersText(NSDictionary *h) {
    if (![h isKindOfClass:[NSDictionary class]] || !h.count) return @"(无)";
    NSArray *keys = [[h allKeys] sortedArrayUsingSelector:@selector(compare:)];
    NSMutableString *s = [NSMutableString string];
    for (NSString *k in keys) [s appendFormat:@"%@: %@\n", k, h[k]];
    return s.length ? s : @"(无)";
}

// body 尽量解成可读文本；JSON 就美化，二进制只报大小
static NSString *FCNetBodyText(NSData *d) {
    if (!d.length) return @"(空)\n";
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (!s) s = [[NSString alloc] initWithData:d encoding:NSISOLatin1StringEncoding];
    if (!s) return [NSString stringWithFormat:@"(二进制 %@)\n", FCNetSizeText(d.length)];
    // JSON 美化
    NSString *trim = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trim.length > 1 && ([trim hasPrefix:@"{"] || [trim hasPrefix:@"["])) {
        NSData *dd = [s dataUsingEncoding:NSUTF8StringEncoding];
        id obj = [NSJSONSerialization JSONObjectWithData:dd options:0 error:nil];
        if (obj) {
            NSData *pretty = [NSJSONSerialization dataWithJSONObject:obj
                                                             options:NSJSONWritingPrettyPrinted
                                                               error:nil];
            if (pretty) {
                NSString *ps = [[NSString alloc] initWithData:pretty encoding:NSUTF8StringEncoding];
                if (ps.length) return ps;
            }
        }
    }
    return s;
}

static NSString *FCNetDetailText(FCNetRecord *r) {
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"%@  %@\n", r.method, r.url ?: @"-"];
    [s appendFormat:@"状态 %ld   耗时 %.0fms   来源 %@   时间 %@\n",
        (long)r.status, r.cost * 1000, r.source ?: @"-",
        [NSDateFormatter localizedStringFromDate:r.date dateStyle:NSDateFormatterNoStyle
                                      timeStyle:NSDateFormatterMediumStyle]];
    if (r.note.length) [s appendFormat:@"标记 %@\n", r.note];
    if (r.failed && r.errText.length) [s appendFormat:@"错误 %@\n", r.errText];
    [s appendString:@"\n▍请求头\n"];
    [s appendString:FCNetHeadersText(r.reqHeaders)];
    [s appendString:@"\n▍请求体\n"];
    [s appendString:FCNetBodyText(r.reqBody)];
    [s appendString:@"\n▍响应头\n"];
    [s appendString:FCNetHeadersText(r.respHeaders)];
    [s appendString:@"\n▍响应体\n"];
    [s appendString:FCNetBodyText(r.respBody)];
    return s;
}

#pragma mark - 列表 cell

// v56：列表改卡片式（白底圆角 + 间距），左侧一条细色条表示状态：
// 红=疑似广告接口、橙=失败、绿=正常。原来整屏白板 + 灰字，一条条分不出轻重。
@interface FCNetCell : UITableViewCell
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) UIView *bar;
@property (nonatomic, strong) UILabel *line1;
@property (nonatomic, strong) UILabel *line2;
@property (nonatomic, strong) UILabel *right;
@end

@implementation FCNetCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    self.backgroundColor = [UIColor clearColor];
    self.contentView.backgroundColor = [UIColor clearColor];
    self.selectionStyle = UITableViewCellSelectionStyleNone;

    _card = [[UIView alloc] init];
    _card.backgroundColor = [UIColor whiteColor];
    _card.layer.cornerRadius = 10;
    _card.layer.borderWidth = 1.0 / [UIScreen mainScreen].scale;
    _card.layer.borderColor = FCLine().CGColor;
    [self.contentView addSubview:_card];

    _bar = [[UIView alloc] init];
    _bar.backgroundColor = [UIColor clearColor];
    _bar.layer.cornerRadius = 1.5;
    [_card addSubview:_bar];

    _line1 = [[UILabel alloc] init];
    _line1.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightMedium];
    _line1.textColor = FCInk();
    _line1.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [_card addSubview:_line1];

    _line2 = [[UILabel alloc] init];
    _line2.font = [UIFont systemFontOfSize:10.5];
    _line2.textColor = FCMuted();
    _line2.lineBreakMode = NSLineBreakByTruncatingTail;
    [_card addSubview:_line2];

    _right = [[UILabel alloc] init];
    _right.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightSemibold];
    _right.textAlignment = NSTextAlignmentRight;
    [_card addSubview:_right];
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.contentView.bounds.size.width;
    CGFloat h = self.contentView.bounds.size.height;
    CGFloat cw = w - 24;
    _card.frame = CGRectMake(12, 3, cw, h - 6);
    _bar.frame = CGRectMake(0, 12, 3, h - 24);
    _right.frame = CGRectMake(cw - 74, 10, 60, 16);
    _line1.frame = CGRectMake(13, 10, cw - 13 - 80, 16);
    _line2.frame = CGRectMake(13, 29, cw - 26, 14);
}
@end

#pragma mark - 面板控制器

@interface FCNetVC : UIViewController <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UISearchBar *search;
@property (nonatomic, strong) UIButton *toggleBtn;
@property (nonatomic, strong) UILabel *statusLabel;    // v53：接管/记录/跳过 计数
@property (nonatomic, strong) UILabel *emptyLabel;     // v53：空状态说明
@property (nonatomic, strong) UITextView *detail;
@property (nonatomic, strong) UIView *detailBar;
@property (nonatomic, strong) NSArray<FCNetRecord *> *rows;
@property (nonatomic, copy)   NSString *filter;
@property (nonatomic, strong) FCNetRecord *currentDetailRecord;
@property (nonatomic, strong) FCNetAnalysis *analysis;      // v54：当前分析结果
@property (nonatomic, assign) BOOL showingAnalysis;         // v54：详情页正在显示分析报告
@property (nonatomic, strong) UIButton *applyBtn;           // v54：「添加建议规则」
@property (nonatomic, weak)   UIAlertController *patternAlert;   // v54：规则向导第1步弹窗
// v55：全站一键分析
@property (nonatomic, strong) FCNetGlobalAnalysis *globalAnalysis;
@property (nonatomic, assign) BOOL showingGlobal;            // 详情页正在显示「全站」报告
@property (nonatomic, strong) UIButton *analyzeAllBtn;       // 列表页的大按钮
- (void)reloadRows;
- (void)fcPresent:(UIViewController *)vc;   // v52：延后一个 runloop 再 present
- (void)fcPresent:(UIViewController *)vc attempt:(NSInteger)n;
- (void)fcBack;                             // v52：回到列表（重开面板时复位）
// 下面这些都被 @selector(...) 引用，先声明出来——否则编译器在 viewDidLoad 处
// 还不知道它们存在，会报「undeclared selector」警告。
- (void)fcClose;
- (void)fcClear;
- (void)fcRules;
- (void)fcCopyAll;
- (void)fcCopyOne;
- (void)fcToggle;
- (void)syncToggleTitle;
- (void)refreshStatus;
- (void)fcMode;
- (void)fcAnalyze;                          // v54：一键分析当前记录
- (void)fcAnalyzeAll;                       // v55：分析当前全部抓包数据（不用选记录）
- (void)fcApplyGlobal;                      // v55：一键处理全站建议
- (void)fcApplySuggestions;                 // v54：把分析建议加成规则
- (void)patternFieldChanged:(UITextField *)tf;   // v54：正则实时回测
- (NSString *)patternHintFor:(NSString *)pattern;
- (void)fcPreviewPattern:(NSString *)pattern;    // v54：列出实际命中的 URL 样本
- (void)fcAddRuleStep1;
- (void)fcAddRuleStep2:(NSString *)pattern;
- (void)fcMockRule:(NSString *)pattern;
- (void)fcBodyRule:(NSString *)pattern isRequest:(BOOL)isReq;
- (NSString *)suggestedURLPattern;
@end

@implementation FCNetVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = FCBg();
    CGFloat w = self.view.bounds.size.width;
    // v52：顶部留白按真实状态栏算。硬写 44 在灵动岛机型（54pt）上会压住状态栏，
    // 在无刘海机型上又空出一截。statusBarFrame 已废弃但仍可用，取最大值兜底。
    CGFloat sbTop = [UIApplication sharedApplication].statusBarFrame.size.height;
    CGFloat top = MAX(44, sbTop);

    // 顶部条
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, top, w, 40)];
    bar.backgroundColor = [UIColor whiteColor];
    [self.view addSubview:bar];
    UIView *barHair = [[UIView alloc] initWithFrame:CGRectMake(0, 39.5, w, 0.5)];
    barHair.backgroundColor = FCLine();
    [bar addSubview:barHair];

    CGFloat x = 8;
    UIButton *(^mk)(NSString *, SEL) = ^UIButton *(NSString *title, SEL act) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        [b setTitle:title forState:UIControlStateNormal];
        [b setTitleColor:FCDeep() forState:UIControlStateNormal];
        b.backgroundColor = [UIColor whiteColor];
        b.layer.cornerRadius = 8;
        b.layer.borderWidth = 1.0 / [UIScreen mainScreen].scale;
        b.layer.borderColor = FCLine().CGColor;
        [b addTarget:self action:act forControlEvents:UIControlEventTouchUpInside];
        return b;
    };
    NSArray *titles = @[@"关闭", @"清空", @"规则", @"复制", @"模式"];
    NSArray *sels = @[@"fcClose", @"fcClear", @"fcRules", @"fcCopyAll", @"fcMode"];
    CGFloat bw = (w - 16 - 4 * 6) / 5.0;
    for (NSUInteger i = 0; i < titles.count; i++) {
        UIButton *b = mk(titles[i], NSSelectorFromString(sels[i]));
        b.frame = CGRectMake(x, 7, bw, 26);
        [bar addSubview:b];
        x += bw + 6;
    }

    // 开关按钮单独一行（要显示当前状态，文字会变）
    self.toggleBtn = mk(@"采集：关", @selector(fcToggle));
    self.toggleBtn.frame = CGRectMake(12, top + 46, w - 24, 30);
    self.toggleBtn.backgroundColor = FCGreen();
    self.toggleBtn.layer.cornerRadius = 9;
    self.toggleBtn.layer.borderWidth = 0;
    self.toggleBtn.titleLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightSemibold];
    [self.toggleBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [self.view addSubview:self.toggleBtn];
    [self syncToggleTitle];

    // v55：一键分析——老大要的是「没有基础的人也能傻瓜式完成」，所以放一个整行大按钮，
    // 不需要先理解列表、不需要先选中某条记录、不需要懂 JSON。
    self.analyzeAllBtn = mk(@"🧠 一键分析全部流量（给建议）", @selector(fcAnalyzeAll));
    self.analyzeAllBtn.frame = CGRectMake(12, top + 84, w - 24, 38);
    self.analyzeAllBtn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    self.analyzeAllBtn.backgroundColor = [UIColor colorWithRed:1.0 green:0.45 blue:0.10 alpha:1];
    self.analyzeAllBtn.layer.cornerRadius = 11;
    self.analyzeAllBtn.layer.borderWidth = 0;
    self.analyzeAllBtn.layer.shadowColor = [UIColor colorWithRed:1.0 green:0.45 blue:0.10 alpha:1].CGColor;
    self.analyzeAllBtn.layer.shadowOpacity = 0.30;
    self.analyzeAllBtn.layer.shadowRadius = 7;
    self.analyzeAllBtn.layer.shadowOffset = CGSizeMake(0, 4);
    [self.analyzeAllBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [self.view addSubview:self.analyzeAllBtn];

    // v53：状态行——上一版面板什么都没显示，老大只能说「没有记录」，
    // 分不清是「没开采集」「开了但一条没抓到」还是「抓到了但列表是空的」。
    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, top + 130, w - 28, 14)];
    self.statusLabel.font = [UIFont systemFontOfSize:10.5];
    self.statusLabel.textColor = FCMuted();
    [self.view addSubview:self.statusLabel];

    // 搜索框
    UIView *searchWrap = [[UIView alloc] initWithFrame:CGRectMake(12, top + 150, w - 24, 36)];
    searchWrap.backgroundColor = [UIColor whiteColor];
    searchWrap.layer.cornerRadius = 9;
    searchWrap.layer.borderWidth = 1.0 / [UIScreen mainScreen].scale;
    searchWrap.layer.borderColor = FCLine().CGColor;
    [self.view addSubview:searchWrap];
    self.search = [[UISearchBar alloc] initWithFrame:CGRectMake(2, 0, w - 28, 36)];
    self.search.searchBarStyle = UISearchBarStyleMinimal;
    self.search.placeholder = @"过滤：方法 / 域名 / 路径";
    self.search.delegate = self;
    self.search.backgroundImage = [[UIImage alloc] init];
    [searchWrap addSubview:self.search];

    CGFloat listTop = top + 192;
    self.table = [[UITableView alloc] initWithFrame:CGRectMake(0, listTop, w, self.view.bounds.size.height - listTop)
                                              style:UITableViewStylePlain];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.rowHeight = 58;
    self.table.backgroundColor = [UIColor clearColor];
    self.table.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.table.contentInset = UIEdgeInsetsMake(6, 0, 24, 0);
    self.table.showsVerticalScrollIndicator = NO;
    [self.view addSubview:self.table];

    // v53：空状态说明——列表为空时告诉老大「为什么空、该做什么」，
    // 而不是让他面对一个白板猜。
    self.emptyLabel = [[UILabel alloc] initWithFrame:CGRectMake(28, listTop + 50, w - 56, 170)];
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.font = [UIFont systemFontOfSize:12.5];
    self.emptyLabel.textColor = FCMuted();
    self.emptyLabel.text =
        @"还没有记录\n\n"
        @"① 上面要是「采集：开」\n"
        @"② 回 App 点几下、下拉刷新\n"
        @"③ 图片/脚本不算，只看接口\n\n"
        @"然后点橙色「一键分析」，\n红色就是可疑的广告接口。";
    self.emptyLabel.hidden = YES;
    [self.view addSubview:self.emptyLabel];

    // 详情层（默认隐藏）
    self.detailBar = [[UIView alloc] initWithFrame:CGRectMake(0, top, w, 44)];
    self.detailBar.backgroundColor = [UIColor whiteColor];
    self.detailBar.hidden = YES;
    UIView *dbarHair = [[UIView alloc] initWithFrame:CGRectMake(0, 43.5, w, 0.5)];
    dbarHair.backgroundColor = FCLine();
    [self.detailBar addSubview:dbarHair];
    UIButton *back = mk(@"← 返回", @selector(fcBack));
    back.frame = CGRectMake(10, 8, 70, 28);
    [self.detailBar addSubview:back];
    // v54：一键分析——放在最显眼的位置，这是本轮的主要入口
    UIButton *analyze = mk(@"🔍 分析", @selector(fcAnalyze));
    analyze.frame = CGRectMake(88, 8, 72, 28);
    analyze.backgroundColor = [UIColor colorWithRed:1.0 green:0.45 blue:0.10 alpha:1];
    analyze.layer.borderWidth = 0;
    analyze.layer.cornerRadius = 9;
    [analyze setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [analyze setTitleColor:[UIColor whiteColor] forState:UIControlStateHighlighted];
    [self.detailBar addSubview:analyze];
    // v54：分析结果页才出现——把建议规则一键加进规则引擎（v55：全站模式下变「一键处理」）
    self.applyBtn = mk(@"＋ 添加建议", @selector(fcApplySuggestions));
    self.applyBtn.frame = CGRectMake(w - 202, 8, 128, 28);
    self.applyBtn.backgroundColor = FCGreen();
    self.applyBtn.layer.borderWidth = 0;
    self.applyBtn.layer.cornerRadius = 9;
    [self.applyBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.applyBtn.hidden = YES;
    [self.detailBar addSubview:self.applyBtn];
    UIButton *copyOne = mk(@"复制", @selector(fcCopyOne));
    copyOne.frame = CGRectMake(w - 66, 8, 56, 28);
    [self.detailBar addSubview:copyOne];
    [self.view addSubview:self.detailBar];

    self.detail = [[UITextView alloc] initWithFrame:CGRectMake(0, top + 44, w,
                                                              self.view.bounds.size.height - top - 44)];
    self.detail.editable = NO;
    self.detail.selectable = YES;
    self.detail.alwaysBounceVertical = YES;
    self.detail.textContainerInset = UIEdgeInsetsMake(16, 16, 30, 16);   // v56：留白
    self.detail.backgroundColor = [UIColor whiteColor];
    self.detail.hidden = YES;
    [self.view addSubview:self.detail];

    [self reloadRows];
}

- (void)syncToggleTitle {
    BOOL on = FCNetEnabled();
    [self.toggleBtn setTitle:(on ? @"采集：开（正在记录流量）" : @"采集：关（点这里开启）")
                    forState:UIControlStateNormal];
    self.toggleBtn.backgroundColor = on ? FCGreen() : FCMuted();
}

- (void)reloadRows {
    NSArray *all = FCNetRecords();
    NSString *f = [self.filter stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (f.length) {
        NSMutableArray *out = [NSMutableArray array];
        for (FCNetRecord *r in all) {
            NSString *hay = [NSString stringWithFormat:@"%@ %@ %@ %ld",
                             r.method ?: @"", r.host ?: @"", r.path ?: @"", (long)r.status];
            if ([hay rangeOfString:f options:NSCaseInsensitiveSearch].location != NSNotFound)
                [out addObject:r];
        }
        self.rows = out;
    } else {
        self.rows = all;
    }
    [self.table reloadData];
    [self refreshStatus];
    // v53：空状态只在「没有过滤条件 + 确实没记录」时出现，
    // 搜索无结果时不要误导成「没抓到」。
    BOOL showEmpty = (self.rows.count == 0);
    self.emptyLabel.hidden = !showEmpty;
    if (showEmpty && !self.detail.hidden) self.emptyLabel.hidden = YES;
}

// v53：状态行。四个数字分别对应「有没有在干活」的四个环节，
// 老大截图一眼就能看出卡在哪一环：
//   接管 0        → 采集没开，或 App 还没发出 http(s) 请求
//   接管 >0 记录 0 → 接管了但记录被去重/裁剪，或面板刷新没触发
//   跳过静态 >0    → 确实在跑，只是这条是图片/脚注
- (void)refreshStatus {
    NSString *mode = @"采集已关";
    if (FCNetEnabled()) {
        mode = FCNetListenOnly() ? @"安全模式（不接管）" : @"接管采集中";
    }
    NSUInteger hot = 0;
    for (FCNetRecord *r in self.rows) if (r.suspectScore >= 3) hot++;
    NSString *tail = hot ? [NSString stringWithFormat:@" · 可疑 %lu", (unsigned long)hot] : @"";
    self.statusLabel.text = [NSString stringWithFormat:
        @"%@ · 接管 %lu · 记录 %lu%@",
        mode,
        (unsigned long)FCNetHandledCount(),
        (unsigned long)FCNetRecordCount(), tail];
}

#pragma mark 动作

- (void)fcClose { FCNetHidePanel(); }

- (void)fcClear {
    FCNetClearRecords();
    [self reloadRows];
}

- (void)fcToggle {
    FCNetSetEnabled(!FCNetEnabled());
    [self syncToggleTitle];
    [self reloadRows];
}

// v53：采集模式切换
- (void)fcMode {
    BOOL listen = FCNetListenOnly();
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"采集模式"
        message:(listen
            ? @"当前：安全模式（不接管）。一条都不会记录，App 完全不受影响。"
            : @"当前：接管模式。能看到完整请求/响应，也能改写与阻断。")
        preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"接管模式（采集全量·可改写）"
                 style:UIAlertActionStyleDefault
                 handler:^(UIAlertAction *a){
                     FCNetSetListenOnly(NO);
                     [self reloadRows];
                     [self toast:@"已切到接管模式"];
                 }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"安全模式（完全不接管·零风险）"
                 style:UIAlertActionStyleDestructive
                 handler:^(UIAlertAction *a){
                     FCNetSetListenOnly(YES);
                     [self reloadRows];
                     [self toast:@"已切到安全模式·不再记录"];
                 }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (ac.popoverPresentationController) {
        ac.popoverPresentationController.sourceView = self.view;
        ac.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, 60, 1, 1);
    }
    [self fcPresent:ac];
}

- (void)fcCopyAll {
    NSMutableString *s = [NSMutableString string];
    for (FCNetRecord *r in self.rows) {
        [s appendFormat:@"%@ %@ -> %ld (%.0fms)\n", r.method, r.url, (long)r.status, r.cost * 1000];
    }
    [UIPasteboard generalPasteboard].string = s.length ? s : @"(无记录)";
    [self toast:@"已复制全部 URL"];
}

- (void)fcCopyOne {
    // v55：全站报告页上「复制」复制整篇报告
    if (self.showingGlobal && self.globalAnalysis.report.length) {
        [UIPasteboard generalPasteboard].string = self.globalAnalysis.report;
        [self toast:@"已复制全站分析报告"];
        return;
    }
    // v54：分析页上「复制」复制的是分析报告，不是原始报文
    if (self.showingAnalysis && self.analysis.report.length) {
        [UIPasteboard generalPasteboard].string = self.analysis.report;
        [self toast:@"已复制分析报告"];
        return;
    }
    FCNetRecord *r = self.currentDetailRecord;
    if (!r) return;
    [UIPasteboard generalPasteboard].string = FCNetDetailText(r);
    [self toast:@"已复制这条（含头与体）"];
}

// ===== v55：全站一键分析 =====
// 和 v54 的「看某一条」不同，这里连记录都不用选：分析当前抓到的**全部**流量，
// 自己归组、打分、排序，直接告诉老大「有几个接口可疑、能关几处开关、下一步点什么」。
// （v54 的单条分析仍在：详情页「🔍 分析」——为什么放在详情页而不是列表长按？
//   因为用户看的是「这一条」，分析也必须针对这一条，列表上多一个手势反而容易误触。）
- (void)fcAnalyzeAll {
    FCNetGlobalAnalysis *g = FCNetAnalyzeAllRecords();
    self.globalAnalysis = g;
    self.showingGlobal = YES;
    self.analysis = nil;
    self.showingAnalysis = NO;

    self.detail.attributedText = FCNetReportAttr(g.report);   // v56：可疑标红
    self.detail.contentOffset = CGPointZero;
    self.detail.hidden = NO;
    self.detailBar.hidden = NO;
    self.table.hidden = YES;
    self.search.hidden = YES;
    self.toggleBtn.hidden = YES;
    self.analyzeAllBtn.hidden = YES;
    self.statusLabel.hidden = YES;
    self.emptyLabel.hidden = YES;

    // v56：老大反馈「报告可以生成，没有一键处理」——上一版在「0 处可改」时把按钮藏了，
    // 看起来像功能没做。现在按钮常显：有活干就说能关几处，没活干就给手动入口。
    BOOL has = (g.rules.count > 0);
    self.applyBtn.hidden = NO;
    self.applyBtn.enabled = YES;
    self.applyBtn.backgroundColor = has ? FCGreen()
                                        : [UIColor colorWithRed:0.55 green:0.58 blue:0.63 alpha:1];
    [self.applyBtn setTitle:(has ? [NSString stringWithFormat:@"一键处理 %lu 处",
                                    (unsigned long)g.rules.count]
                                 : @"怎么手动改")
                   forState:UIControlStateNormal];

    // v56：把每一族的结构分写回记录，返回列表时这些接口就是红的。
    // 只看 URL 关键词会漏掉 /v2/m/d 这类接口——它们的可疑点全在响应体里。
    NSMutableDictionary<NSString *, NSNumber *> *scoreOf = [NSMutableDictionary dictionary];
    for (FCNetGroupStat *st in g.groups) {
        if (st.pattern.length && st.score > 0) scoreOf[st.pattern] = @(st.score);
    }
    if (scoreOf.count) {
        for (FCNetRecord *r in FCNetRecords()) {
            NSString *pat = FCNetAutoPatternForURL(r.url ?: @"");
            NSNumber *sc = pat.length ? scoreOf[pat] : nil;
            if (sc && sc.integerValue > r.suspectScore) r.suspectScore = sc.integerValue;
        }
    }

    if (!g.recordCount) {
        [self toast:@"还没有记录，先回 App 刷新几次"];
    } else if (!g.rules.count) {
        [self toast:@"没找到能自动处理的广告开关"];
    } else {
        [self toast:[NSString stringWithFormat:@"%lu 个可疑接口 · %lu 处可关",
                     (unsigned long)g.suspectCount, (unsigned long)g.rules.count]];
    }
}

// 一键处理：**只关开关、不阻断接口**。阻断会让页面缺块甚至白屏，
// 对「没基础的人」来说是不可接受的副作用，这条路只能留在详情页手动做。
- (void)fcApplyGlobal {
    NSArray<NSDictionary *> *rules = self.globalAnalysis.rules;
    if (!rules.count) {
        // 不是「失败」，是「这次没找到」。给两条能立刻走的路，别让老大对着提示发呆。
        UIAlertController *ac = [UIAlertController
            alertControllerWithTitle:@"这次没有能自动改的"
            message:@"广告开关没被认出来。\n\n"
                     @"① 回 App 多点几个页面，把广告刷出来，再点一次「一键分析」\n"
                     @"② 或进列表点某一条 →「分析」，看那条有没有可加的建议"
            preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]];
        [self fcPresent:ac];
        return;
    }

    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"一键处理"
        message:[NSString stringWithFormat:
                 @"会把 %lu 处广告开关/列表改成关闭。\n\n"
                 @"只关开关，不断接口——最坏结果是某块内容空着，不会白屏。\n"
                 @"随时可以在「规则」里删掉，删了就立刻恢复。",
                 (unsigned long)rules.count]
        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"开始处理" style:UIAlertActionStyleDefault
                 handler:^(UIAlertAction *a){
                     for (NSDictionary *r in rules) FCNetAddRule(r);
                     [self.applyBtn setTitle:@"已处理" forState:UIControlStateNormal];
                     self.applyBtn.enabled = NO;
                     [self toast:[NSString stringWithFormat:
                                  @"已关闭 %lu 处 · 回 App 刷新看效果",
                                  (unsigned long)rules.count]];
                 }]];
    [self fcPresent:ac];
}

- (void)fcAnalyze {
    if (self.showingGlobal) { [self fcAnalyzeAll]; return; }   // 全站报告页上点「分析」= 重算
    FCNetRecord *r = self.currentDetailRecord;
    if (!r) { [self toast:@"没有选中的记录"]; return; }
    self.analysis = FCNetAnalyzeRecord(r);
    self.showingAnalysis = YES;
    self.showingGlobal = NO;                  // v55：单条模式
    self.globalAnalysis = nil;
    self.detail.attributedText = FCNetReportAttr(self.analysis.report);   // v56：可疑标红
    self.detail.contentOffset = CGPointZero;
    self.applyBtn.hidden = NO;
    self.applyBtn.enabled = YES;
    self.applyBtn.backgroundColor = FCGreen();
    [self.applyBtn setTitle:@"＋ 添加建议" forState:UIControlStateNormal];
    // 建议多于「只有阻断」时才值得提示，否则老大点了也只有一个选项
    if (self.analysis.suggestedRules.count > 1) {
        [self toast:[NSString stringWithFormat:@"分析完成·%lu 条建议",
                     (unsigned long)self.analysis.suggestedRules.count]];
    }
}

- (void)fcApplySuggestions {
    if (self.showingGlobal) { [self fcApplyGlobal]; return; }   // v55：全站报告 → 一键处理
    if (!self.showingAnalysis) { [self fcAnalyze]; return; }
    NSArray<NSDictionary *> *rules = self.analysis.suggestedRules;
    if (!rules.count) { [self toast:@"没有可添加的建议"]; return; }

    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"添加到规则"
        message:@"选中即刻生效（不需要重新抓包）"
        preferredStyle:UIAlertControllerStyleActionSheet];

    for (NSUInteger i = 0; i < rules.count; i++) {
        NSDictionary *rule = rules[i];
        NSString *title = FCNetRuleExplain(rule);
        if (title.length > 56) title = [[title substringToIndex:56] stringByAppendingString:@"…"];
        [ac addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *a){
                FCNetAddRule(rule);
                [self toast:@"已添加该规则"];
            }]];
    }
    if (rules.count > 1) {
        [ac addAction:[UIAlertAction actionWithTitle:@"全部添加" style:UIAlertActionStyleDestructive
            handler:^(UIAlertAction *a){
                for (NSDictionary *rule in rules) FCNetAddRule(rule);
                [self toast:[NSString stringWithFormat:@"已添加 %lu 条规则",
                             (unsigned long)rules.count]];
            }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (ac.popoverPresentationController) {
        ac.popoverPresentationController.sourceView = self.detailBar;
        ac.popoverPresentationController.sourceRect = self.applyBtn.frame;
    }
    [self fcPresent:ac];
}

- (void)fcBack {
    self.detail.hidden = YES;
    self.detailBar.hidden = YES;
    self.table.hidden = NO;
    self.search.hidden = NO;
    self.toggleBtn.hidden = NO;
    self.analyzeAllBtn.hidden = NO;   // v55
    self.statusLabel.hidden = NO;
    self.detail.attributedText = nil;
    self.currentDetailRecord = nil;
    // v54：退出详情时清掉分析状态，否则下次点开别的记录还带着上一份报告
    self.analysis = nil;
    self.showingAnalysis = NO;
    // v55：全站报告也要清，并把「一键处理」按钮复位（否则下次进单条分析还是「已处理」）
    self.globalAnalysis = nil;
    self.showingGlobal = NO;
    self.applyBtn.hidden = YES;
    self.applyBtn.enabled = YES;
    self.applyBtn.backgroundColor = FCGreen();
    [self.applyBtn setTitle:@"＋ 添加建议" forState:UIControlStateNormal];
    [self reloadRows];   // v53：回来时重算空状态与计数
}

- (void)toast:(NSString *)msg {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(20, self.view.bounds.size.height - 90,
                                                          self.view.bounds.size.width - 40, 34)];
    l.text = msg;
    l.textAlignment = NSTextAlignmentCenter;
    l.font = [UIFont systemFontOfSize:12];
    l.textColor = [UIColor whiteColor];
    l.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.75];
    l.layer.cornerRadius = 8; l.clipsToBounds = YES;
    [self.view addSubview:l];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [l removeFromSuperview]; });
}

// v52：从 UIAlertAction 的 handler 里直接 present 下一个弹窗，iOS 13+ 经常报
// "Attempt to present ... while a presentation is in progress" 然后**静默失败**——
// 表现就是点了「下一步」什么都没发生。这里等上一个弹窗真正退场再 present，
// 最多等 6×0.12s；等不到就放弃（说明确实有别的东西挡着），绝不吞掉用户的操作意图。
- (void)fcPresent:(UIViewController *)vc {
    [self fcPresent:vc attempt:0];
}

- (void)fcPresent:(UIViewController *)vc attempt:(NSInteger)n {
    if (self.presentedViewController) {
        if (n >= 6) return;
        __weak typeof(self) ws = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            typeof(self) s = ws;
            if (s) [s fcPresent:vc attempt:n + 1];
        });
        return;
    }
    [self presentViewController:vc animated:YES completion:nil];
}

#pragma mark 规则

- (void)fcRules {
    NSArray<NSDictionary *> *rules = FCNetRules();
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"重写 / 拦截规则"
                              message:(rules.count ? [NSString stringWithFormat:@"当前 %lu 条", (unsigned long)rules.count]
                                                   : @"还没有规则")
                              preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"新增规则" style:UIAlertActionStyleDefault
                 handler:^(UIAlertAction *a){ [self fcAddRuleStep1]; }]];
    for (NSUInteger i = 0; i < rules.count; i++) {
        NSString *title = FCNetRuleExplain(rules[i]);
        if (title.length > 60) title = [[title substringToIndex:60] stringByAppendingString:@"…"];
        [ac addAction:[UIAlertAction actionWithTitle:[@"删除 · " stringByAppendingString:title]
                       style:UIAlertActionStyleDestructive
                       handler:^(UIAlertAction *a){
                           FCNetRemoveRuleAtIndex(i);
                           [self toast:@"已删除该规则"];
                       }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (ac.popoverPresentationController) {
        ac.popoverPresentationController.sourceView = self.view;
        ac.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, 60, 1, 1);
    }
    [self fcPresent:ac];   // v52：延后一帧，避开「正在 presenting」冲突
}

- (void)fcAddRuleStep1 {
    // v54：不再让老大从零写正则。拿最新一条记录自动泛化出正则（域名泛子域、数字段→\d+、
    // 长 token→字符类、query 丢弃），进弹窗时已填好，并当场告诉他这条正则会命中几条。
    NSString *autoPat = [self suggestedURLPattern];   // 注意：不能叫 auto，clang 当关键字
    NSString *seed = autoPat.length ? autoPat : @"";
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:(autoPat.length ? @"第 1 步：URL 正则（已自动生成）" : @"第 1 步：URL 正则")
                         message:[self patternHintFor:seed]
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = seed;
        tf.placeholder = @"正则，匹配完整 URL";
        tf.font = [UIFont fontWithName:@"Menlo" size:12];
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.spellCheckingType = UITextSpellCheckingTypeNo;
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        [tf addTarget:self action:@selector(patternFieldChanged:)
            forControlEvents:UIControlEventEditingChanged];
    }];
    self.patternAlert = ac;
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel
                 handler:^(UIAlertAction *a){ self.patternAlert = nil; }]];
    // 「试匹配」：UIAlertController 的 message 在呈现后改不一定刷新（系统内部不保证），
    // 所以另给一个确定能看结果的入口——列出实际命中的 URL 样本。
    [ac addAction:[UIAlertAction actionWithTitle:@"试匹配" style:UIAlertActionStyleDefault
                 handler:^(UIAlertAction *a){
                     self.patternAlert = nil;
                     [self fcPreviewPattern:(ac.textFields.firstObject.text ?: @"")];
                 }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"下一步" style:UIAlertActionStyleDefault
                 handler:^(UIAlertAction *a){
                     self.patternAlert = nil;
                     [self fcAddRuleStep2:(ac.textFields.firstObject.text ?: @"")];
                 }]];
    [self fcPresent:ac];   // v52：延后一帧，避开「正在 presenting」冲突
}

// 边打字边回测。改 message 是「尽力而为」：能刷新最好，不刷新还有「试匹配」兜底。
- (void)patternFieldChanged:(UITextField *)tf {
    UIAlertController *ac = self.patternAlert;
    if (!ac) return;
    ac.message = [self patternHintFor:(tf.text ?: @"")];
}

- (NSString *)patternHintFor:(NSString *)pattern {
    NSUInteger total = FCNetRecordCount();
    if (!pattern.length) {
        return (total
                ? [NSString stringWithFormat:@"留空 = 匹配全部 %lu 条请求（危险）", (unsigned long)total]
                : @"留空 = 匹配全部请求（危险）");
    }
    if (!FCNetPatternIsValid(pattern)) return @"⚠️ 正则语法错误，这条存不了（查括号和反斜杠）";
    if (!total) return @"✓ 正则可保存；当前还没记录，抓一会儿再回来看命中";
    NSUInteger hit = FCNetPatternHitCount(pattern);
    if (hit == 0) return @"命中 0 条，保存后不会生效（可能漏了路径段或转了义）";
    if (hit >= total && total > 1) {
        return [NSString stringWithFormat:
                @"命中全部 %lu 条，范围过宽（建议在路径里带上接口名）", (unsigned long)total];
    }
    if (hit > 8) {
        return [NSString stringWithFormat:
                @"命中 %lu/%lu 条，偏宽；确认是不是只想改这一族接口",
                (unsigned long)hit, (unsigned long)total];
    }
    return [NSString stringWithFormat:@"✓ 命中 %lu/%lu 条，可保存",
            (unsigned long)hit, (unsigned long)total];
}

// 列出实际命中的 URL（最多 6 条），让老大用眼睛确认正则抓的是不是他要的那族接口。
- (void)fcPreviewPattern:(NSString *)pattern {
    NSArray<NSString *> *hits = pattern.length ? FCNetPatternHits(pattern) : @[];
    NSString *title;
    NSString *body;
    if (!FCNetPatternIsValid(pattern) && pattern.length) {
        title = @"正则无效";
        body = @"括号 / 反斜杠 / 字符类有问题，改好再试。";
    } else if (!hits.count) {
        title = @"命中 0 条";
        body = (FCNetRecordCount()
                ? @"当前记录里没有 URL 匹配这条正则。\n可把路径段删短一点再试。"
                : @"还没有采集到记录，先去触发几个请求。");
    } else {
        NSUInteger n = hits.count;
        NSUInteger total = FCNetRecordCount();
        title = [NSString stringWithFormat:@"命中 %lu 条（共 %lu 条记录）",
                 (unsigned long)FCNetPatternHitCount(pattern), (unsigned long)total];
        NSMutableArray *lines = [NSMutableArray array];
        for (NSUInteger i = 0; i < n && i < 6; i++) {
            NSString *u = hits[i];
            if (u.length > 110) u = [[u substringToIndex:110] stringByAppendingString:@"…"];
            [lines addObject:u];
        }
        if (n > 6) [lines addObject:[NSString stringWithFormat:@"… 另有 %lu 条", (unsigned long)(n - 6)]];
        body = [lines componentsJoinedByString:@"\n"];
    }
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
                              message:body preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"返回修改" style:UIAlertActionStyleCancel
                 handler:^(UIAlertAction *a){ [self fcAddRuleStep1]; }]];
    if (hits.count) {
        [ac addAction:[UIAlertAction actionWithTitle:@"就用这条" style:UIAlertActionStyleDefault
                     handler:^(UIAlertAction *a){ [self fcAddRuleStep2:pattern]; }]];
    }
    [self fcPresent:ac];
}

- (NSString *)suggestedURLPattern {
    // v54：改用自动泛化。旧的 FCNetSuggestedRuleForRecord 生成的常带死值（时间戳、设备号），
    // 换个请求就匹配不上；FCNetAutoPatternForURL 才是按「这一族接口」归纳的。
    NSArray *all = FCNetRecords();
    FCNetRecord *r = all.lastObject;
    if (!r) return @"";
    NSString *p = FCNetAutoPatternForURL(r.url);
    if (p.length && FCNetPatternHitCount(p) == 0) {
        // 泛化后连自己都不命中（极少见，一般是 URL 里有怪异编码）→ 原串转义兜底
        p = [NSRegularExpression escapedPatternForString:r.url];
    }
    return p ?: @"";
}

- (void)fcAddRuleStep2:(NSString *)pattern {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"第 2 步：动作"
                              message:@"选中后按提示填参数"
                              preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"阻断请求（直接失败）" style:UIAlertActionStyleDestructive
                 handler:^(UIAlertAction *a){
                     FCNetAddRule(@{@"name": @"阻断", @"url": pattern ?: @"",
                                    @"method": @"*", @"block": @YES, @"enabled": @YES});
                     [self toast:@"已新增：阻断规则"];
                 }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"伪造响应（填状态+JSON）" style:UIAlertActionStyleDefault
                 handler:^(UIAlertAction *a){ [self fcMockRule:pattern]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"改请求体（查找→替换）" style:UIAlertActionStyleDefault
                 handler:^(UIAlertAction *a){ [self fcBodyRule:pattern isRequest:YES]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"改响应体（查找→替换）" style:UIAlertActionStyleDefault
                 handler:^(UIAlertAction *a){ [self fcBodyRule:pattern isRequest:NO]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (ac.popoverPresentationController) {
        ac.popoverPresentationController.sourceView = self.view;
        ac.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, 60, 1, 1);
    }
    [self fcPresent:ac];   // v52：延后一帧，避开「正在 presenting」冲突
}

- (void)fcMockRule:(NSString *)pattern {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"伪造响应"
                              message:@"第一行状态码，其余作为 JSON 响应体"
                              preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = @"200";
        tf.keyboardType = UIKeyboardTypeNumberPad;
        tf.placeholder = @"状态码";
    }];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = @"{}";
        tf.font = [UIFont fontWithName:@"Menlo" size:12];
        tf.placeholder = @"响应体";
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault
                 handler:^(UIAlertAction *a){
                     NSInteger st = [ac.textFields[0].text integerValue] ?: 200;
                     NSString *body = ac.textFields[1].text ?: @"{}";
                     FCNetAddRule(@{@"name": @"伪造", @"url": pattern ?: @"", @"method": @"*",
                                    @"mock": @{@"status": @(st),
                                               @"headers": @{@"Content-Type": @"application/json"},
                                               @"body": body},
                                    @"enabled": @YES});
                     [self toast:@"已新增：伪造响应规则"];
                 }]];
    [self fcPresent:ac];   // v52：延后一帧，避开「正在 presenting」冲突
}

- (void)fcBodyRule:(NSString *)pattern isRequest:(BOOL)isReq {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:(isReq ? @"改请求体" : @"改响应体")
                              message:@"查找串 → 替换串（替换留空 = 删除）"
                              preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.placeholder = @"查找"; }];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.placeholder = @"替换（可空）"; }];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault
                 handler:^(UIAlertAction *a){
                     NSString *find = ac.textFields[0].text ?: @"";
                     NSString *repl = ac.textFields[1].text ?: @"";
                     if (!find.length) { [self toast:@"查找串不能为空"]; return; }
                     NSMutableDictionary *d = [NSMutableDictionary dictionary];
                     d[@"name"] = isReq ? @"改请求体" : @"改响应体";
                     d[@"url"] = pattern ?: @"";
                     d[@"method"] = @"*";
                     d[@"enabled"] = @YES;
                     if (isReq) { d[@"reqBodyFind"] = find; d[@"reqBodyReplace"] = repl; }
                     else       { d[@"respBodyFind"] = find; d[@"respBodyReplace"] = repl; }
                     FCNetAddRule(d);
                     [self toast:isReq ? @"已新增：改请求体规则" : @"已新增：改响应体规则"];
                 }]];
    [self fcPresent:ac];   // v52：延后一帧，避开「正在 presenting」冲突
}

#pragma mark 搜索

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    self.filter = searchText;
    [self reloadRows];
}
- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar { [searchBar resignFirstResponder]; }

#pragma mark 表格

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.rows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"FCNetCell";
    FCNetCell *c = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!c) c = [[FCNetCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid];
    FCNetRecord *r = self.rows[indexPath.row];
    // v56：可疑接口标红——左侧色条 + 接口名。判据是 suspectScore（采集时按 URL 关键词粗算，
    // 做过「全站分析」后会被结构分覆盖，所以 /v2/m/d 这种没关键词的接口也能被认出来）。
    BOOL hot = (r.suspectScore >= 3);
    c.bar.backgroundColor = hot ? FCRed()
                                : (r.failed ? FCOrange() : [UIColor clearColor]);
    c.line1.textColor = hot ? FCRed() : FCInk();
    c.line1.text = [NSString stringWithFormat:@"%@  %@%@", r.method ?: @"?", r.host ?: @"", r.path ?: @""];
    c.line2.text = [NSString stringWithFormat:@"%@ · %@ · %.0fms · %@",
                    r.respBody.length ? FCNetSizeText(r.respBody.length) : @"-",
                    r.reqBody.length ? [NSString stringWithFormat:@"请求%@", FCNetSizeText(r.reqBody.length)] : @"无体",
                    r.cost * 1000, r.note.length ? r.note : (r.source ?: @"-")];
    if (r.failed) {
        c.right.text = @"失败";
        c.right.textColor = [UIColor colorWithRed:0.62 green:0.62 blue:0.66 alpha:1];
    } else if (r.status >= 400) {
        c.right.text = [NSString stringWithFormat:@"%ld", (long)r.status];
        c.right.textColor = [UIColor colorWithRed:0.85 green:0.2 blue:0.2 alpha:1];
    } else if (r.status > 0) {
        c.right.text = [NSString stringWithFormat:@"%ld", (long)r.status];
        c.right.textColor = [UIColor colorWithRed:0.15 green:0.6 blue:0.3 alpha:1];
    } else {
        c.right.text = @"…";
        c.right.textColor = [UIColor grayColor];
    }
    return c;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    FCNetRecord *r = self.rows[indexPath.row];
    self.currentDetailRecord = r;
    self.detail.attributedText = FCNetReportAttr(FCNetDetailText(r));   // v56：着色
    self.detail.hidden = NO;
    self.detailBar.hidden = NO;
    self.table.hidden = YES;
    self.search.hidden = YES;
    self.toggleBtn.hidden = YES;
    self.statusLabel.hidden = YES;   // v53：详情层全屏覆盖，状态行先收起
    self.analyzeAllBtn.hidden = YES; // v55：详情层压住大按钮，顺手收起来免得透出来
    self.emptyLabel.hidden = YES;
    // v54：换了记录就把上一份分析报告丢掉，否则「＋ 添加建议」会把 A 接口的规则
    // 加到 B 接口的头上（规则里的 url 是 A 的正则，用户完全看不出错）
    self.analysis = nil;
    self.showingAnalysis = NO;
    self.applyBtn.hidden = YES;
}

@end

#pragma mark - 窗口管理

static CFAbsoluteTime gLastRefresh = 0;
static __weak UIWindow *gPrevKeyWin = nil;   // v52：宿主的 key window，关面板时还回去

void FCNetShowPanel(void) {
    // v52：记下原来的 key window。我们的窗口调用 makeKeyAndVisible 之后就成了 key，
    // 关掉时不还回去，宿主 App 的输入框/键盘行为可能异常。
    if (!gNetWin || gNetWin.hidden) {
        for (UIWindow *w in [UIApplication sharedApplication].windows)
            if (w != gNetWin && w.isKeyWindow) { gPrevKeyWin = w; break; }
    }
    if (!gNetWin) {
        CGRect s = [UIScreen mainScreen].bounds;
        gNetWin = [[UIWindow alloc] initWithFrame:s];
        gNetWin.windowLevel = UIWindowLevelAlert + 200;
        gNetWin.backgroundColor = [UIColor whiteColor];
        if (@available(iOS 13.0, *)) {
            // 只认前台活跃的 scene——多 scene App 里取第一个可能拿到后台那个，窗口根本不显示
            for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
                if (![sc isKindOfClass:[UIWindowScene class]]) continue;
                if (sc.activationState != UISceneActivationStateForegroundActive) continue;
                gNetWin.windowScene = (UIWindowScene *)sc;
                break;
            }
        }
        FCNetVC *vc = [[FCNetVC alloc] init];
        gNetVC = vc;
        gNetWin.rootViewController = vc;
    }
    gNetWin.hidden = NO;
    [gNetWin makeKeyAndVisible];
    [(FCNetVC *)gNetVC fcBack];        // 每次打开都回到列表，不留在上次的详情页
    [(FCNetVC *)gNetVC reloadRows];
}

void FCNetHidePanel(void) {
    if (!gNetWin) return;
    gNetWin.hidden = YES;
    // v52：把 key window 交还给宿主
    if (gPrevKeyWin && !gPrevKeyWin.hidden) [gPrevKeyWin makeKeyWindow];
}

BOOL FCNetPanelVisible(void) {
    return gNetWin && !gNetWin.hidden;
}

void FCNetRefreshPanelIfVisible(void) {
    if (!gNetWin || gNetWin.hidden || !gNetVC) return;
    // 节流：抓包时请求很密，每次 push 都 reload 会卡
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - gLastRefresh < 0.35) return;
    gLastRefresh = now;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gNetWin && !gNetWin.hidden && gNetVC) [(FCNetVC *)gNetVC reloadRows];
    });
}

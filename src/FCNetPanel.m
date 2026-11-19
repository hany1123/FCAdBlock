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
    [s appendString:@"\n===== 请求头 =====\n"];
    [s appendString:FCNetHeadersText(r.reqHeaders)];
    [s appendString:@"\n===== 请求体 =====\n"];
    [s appendString:FCNetBodyText(r.reqBody)];
    [s appendString:@"\n===== 响应头 =====\n"];
    [s appendString:FCNetHeadersText(r.respHeaders)];
    [s appendString:@"\n===== 响应体 =====\n"];
    [s appendString:FCNetBodyText(r.respBody)];
    return s;
}

#pragma mark - 列表 cell

@interface FCNetCell : UITableViewCell
@property (nonatomic, strong) UILabel *line1;
@property (nonatomic, strong) UILabel *line2;
@property (nonatomic, strong) UILabel *right;
@end

@implementation FCNetCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    self.backgroundColor = [UIColor whiteColor];
    self.selectionStyle = UITableViewCellSelectionStyleDefault;
    _line1 = [[UILabel alloc] init];
    _line1.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    _line1.textColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.12 alpha:1];
    _line1.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self.contentView addSubview:_line1];
    _line2 = [[UILabel alloc] init];
    _line2.font = [UIFont systemFontOfSize:10];
    _line2.textColor = [UIColor colorWithRed:0.45 green:0.45 blue:0.5 alpha:1];
    _line2.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.contentView addSubview:_line2];
    _right = [[UILabel alloc] init];
    _right.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    _right.textAlignment = NSTextAlignmentRight;
    [self.contentView addSubview:_right];
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.contentView.bounds.size.width;
    CGFloat h = self.contentView.bounds.size.height;
    _right.frame = CGRectMake(w - 96, 8, 88, 16);
    _line1.frame = CGRectMake(12, 8, w - 12 - 100, 16);
    _line2.frame = CGRectMake(12, 26, w - 24, 14);
    (void)h;
}
@end

#pragma mark - 面板控制器

@interface FCNetVC : UIViewController <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UISearchBar *search;
@property (nonatomic, strong) UIButton *toggleBtn;
@property (nonatomic, strong) UITextView *detail;
@property (nonatomic, strong) UIView *detailBar;
@property (nonatomic, strong) NSArray<FCNetRecord *> *rows;
@property (nonatomic, copy)   NSString *filter;
@property (nonatomic, strong) FCNetRecord *currentDetailRecord;
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
- (void)fcAddRuleStep1;
- (void)fcAddRuleStep2:(NSString *)pattern;
- (void)fcMockRule:(NSString *)pattern;
- (void)fcBodyRule:(NSString *)pattern isRequest:(BOOL)isReq;
- (NSString *)suggestedURLPattern;
@end

@implementation FCNetVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.96 green:0.96 blue:0.97 alpha:1];
    CGFloat w = self.view.bounds.size.width;
    // v52：顶部留白按真实状态栏算。硬写 44 在灵动岛机型（54pt）上会压住状态栏，
    // 在无刘海机型上又空出一截。statusBarFrame 已废弃但仍可用，取最大值兜底。
    CGFloat sbTop = [UIApplication sharedApplication].statusBarFrame.size.height;
    CGFloat top = MAX(44, sbTop);

    // 顶部条
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, top, w, 40)];
    bar.backgroundColor = [UIColor whiteColor];
    [self.view addSubview:bar];

    CGFloat x = 8;
    UIButton *(^mk)(NSString *, SEL) = ^UIButton *(NSString *title, SEL act) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        [b setTitle:title forState:UIControlStateNormal];
        b.backgroundColor = [UIColor colorWithRed:0.94 green:0.95 blue:0.97 alpha:1];
        b.layer.cornerRadius = 6;
        [b addTarget:self action:act forControlEvents:UIControlEventTouchUpInside];
        return b;
    };
    NSArray *titles = @[@"关闭", @"清空", @"规则", @"复制"];
    NSArray *sels = @[@"fcClose", @"fcClear", @"fcRules", @"fcCopyAll"];
    CGFloat bw = (w - 16 - 3 * 6) / 4.0;
    for (NSUInteger i = 0; i < titles.count; i++) {
        UIButton *b = mk(titles[i], NSSelectorFromString(sels[i]));
        b.frame = CGRectMake(x, 7, bw, 26);
        [bar addSubview:b];
        x += bw + 6;
    }

    // 开关按钮单独一行（要显示当前状态，文字会变）
    self.toggleBtn = mk(@"采集：关", @selector(fcToggle));
    self.toggleBtn.frame = CGRectMake(8, top + 40, w - 16, 26);
    self.toggleBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.55 blue:0.95 alpha:1];
    [self.toggleBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [self.view addSubview:self.toggleBtn];
    [self syncToggleTitle];

    // 搜索框
    self.search = [[UISearchBar alloc] initWithFrame:CGRectMake(0, top + 72, w, 36)];
    self.search.placeholder = @"过滤：方法 / 域名 / 路径 / 状态码";
    self.search.delegate = self;
    self.search.backgroundImage = [[UIImage alloc] init];
    [self.view addSubview:self.search];

    CGFloat listTop = top + 112;
    self.table = [[UITableView alloc] initWithFrame:CGRectMake(0, listTop, w, self.view.bounds.size.height - listTop)
                                              style:UITableViewStylePlain];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.rowHeight = 48;
    self.table.separatorInset = UIEdgeInsetsMake(0, 12, 0, 12);
    [self.view addSubview:self.table];

    // 详情层（默认隐藏）
    self.detailBar = [[UIView alloc] initWithFrame:CGRectMake(0, top, w, 40)];
    self.detailBar.backgroundColor = [UIColor whiteColor];
    self.detailBar.hidden = YES;
    UIButton *back = mk(@"← 返回列表", @selector(fcBack));
    back.frame = CGRectMake(8, 7, 100, 26);
    [self.detailBar addSubview:back];
    UIButton *copyOne = mk(@"复制这条", @selector(fcCopyOne));
    copyOne.frame = CGRectMake(w - 108, 7, 100, 26);
    [self.detailBar addSubview:copyOne];
    [self.view addSubview:self.detailBar];

    self.detail = [[UITextView alloc] initWithFrame:CGRectMake(0, top + 40, w,
                                                              self.view.bounds.size.height - top - 40)];
    self.detail.editable = NO;
    self.detail.font = [UIFont fontWithName:@"Menlo" size:10] ?: [UIFont systemFontOfSize:10];
    self.detail.backgroundColor = [UIColor whiteColor];
    self.detail.textColor = [UIColor colorWithRed:0.12 green:0.12 blue:0.15 alpha:1];
    self.detail.hidden = YES;
    [self.view addSubview:self.detail];

    [self reloadRows];
}

- (void)syncToggleTitle {
    BOOL on = FCNetEnabled();
    [self.toggleBtn setTitle:(on ? @"采集：开（正在记录流量）" : @"采集：关（点这里开启）")
                    forState:UIControlStateNormal];
    self.toggleBtn.backgroundColor = on
        ? [UIColor colorWithRed:0.15 green:0.6 blue:0.3 alpha:1]
        : [UIColor colorWithRed:0.55 green:0.55 blue:0.6 alpha:1];
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

- (void)fcCopyAll {
    NSMutableString *s = [NSMutableString string];
    for (FCNetRecord *r in self.rows) {
        [s appendFormat:@"%@ %@ -> %ld (%.0fms)\n", r.method, r.url, (long)r.status, r.cost * 1000];
    }
    [UIPasteboard generalPasteboard].string = s.length ? s : @"(无记录)";
    [self toast:@"已复制全部 URL"];
}

- (void)fcCopyOne {
    FCNetRecord *r = self.currentDetailRecord;
    if (!r) return;
    [UIPasteboard generalPasteboard].string = FCNetDetailText(r);
    [self toast:@"已复制这条（含头与体）"];
}

- (void)fcBack {
    self.detail.hidden = YES;
    self.detailBar.hidden = YES;
    self.table.hidden = NO;
    self.search.hidden = NO;
    self.toggleBtn.hidden = NO;
    self.detail.text = nil;
    self.currentDetailRecord = nil;
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
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"第 1 步：URL 匹配"
                              message:@"填正则，留空表示匹配全部请求（危险）"
                              preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"例：api\\.example\\.com/v1/ad";
        tf.font = [UIFont fontWithName:@"Menlo" size:12];
        tf.text = [self suggestedURLPattern];
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"下一步" style:UIAlertActionStyleDefault
                 handler:^(UIAlertAction *a){
                     NSString *p = ac.textFields.firstObject.text ?: @"";
                     [self fcAddRuleStep2:p];
                 }]];
    [self fcPresent:ac];   // v52：延后一帧，避开「正在 presenting」冲突
}

- (NSString *)suggestedURLPattern {
    // 用最新一条记录给个起点，省得老大从零写正则
    NSArray *all = FCNetRecords();
    FCNetRecord *r = all.lastObject;
    if (!r) return @"";
    return FCNetSuggestedRuleForRecord(r) ?: @"";
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
    self.detail.text = FCNetDetailText(r);
    self.detail.hidden = NO;
    self.detailBar.hidden = NO;
    self.table.hidden = YES;
    self.search.hidden = YES;
    self.toggleBtn.hidden = YES;
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

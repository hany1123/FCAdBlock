//
//  FCNetSmart.m —— 抓包数据的一键分析 + 自动正则（v54）
//
//  两件事，都围绕「让老大不用手写正则、不用人肉看 JSON」：
//
//  一、一键分析（FCNetAnalyzeRecord）
//    把一条记录拆成：接口概要 / 请求参数 / 响应结构树 / 广告特征评分 / 可执行建议。
//    建议不是「提示文字」，是**结构完整的规则字典**，点一下就进规则引擎，
//    立即参与阻断或响应体改写。
//
//  二、自动正则（FCNetAutoPatternForURL）
//    原名 FCNetSuggestedRuleForRecord 只会把 6 位以上数字替换成 \d+，太粗糙。
//    这里按 URL 的真实结构泛化：
//      · scheme  → https?
//      · 子域    → ([a-z0-9-]+\.)*   （api.example.com 与 m.example.com 视为同一组）
//      · 纯数字段 → \d+
//      · 长 token / UUID → [A-Za-z0-9_-]{8,}
//      · query 直接丢弃（变化最频繁，留着命中率就归零）
//    并且提供**回测**（FCNetPatternHitCount）：保存前先看这条正则会命中几条，
//    避免一条过宽的正则把全线请求都拦了。
//
//  一条硬约束：本文件不引用 FCAdBlockEntry.m 的任何符号，独立编译。
//
#import "FCNet.h"

#pragma mark - 正则转义 / 域名 / 路径泛化

static NSString *FCReEscape(NSString *s) {
    if (!s.length) return @"";
    static NSCharacterSet *sp = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sp = [NSCharacterSet characterSetWithCharactersInString:@"\\^$.|?*+()[]{}"];
    });
    NSMutableString *o = [NSMutableString stringWithCapacity:s.length + 8];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if ([sp characterIsMember:c]) [o appendString:@"\\"];
        [o appendFormat:@"%C", c];
    }
    return o;
}

// 取可注册域：api.example.com → example.com；a.b.example.com.cn → example.com.cn
static NSString *FCRegistrableDomain(NSString *host) {
    if (!host.length) return nil;
    NSArray *parts = [host.lowercaseString componentsSeparatedByString:@"."];
    if (parts.count <= 2) return host.lowercaseString;
    static NSSet *twoLevel = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        twoLevel = [NSSet setWithArray:@[@"com.cn", @"net.cn", @"org.cn", @"gov.cn", @"edu.cn",
                                         @"co.uk", @"org.uk", @"co.jp", @"ne.jp",
                                         @"com.hk", @"com.tw", @"com.mo", @"com.au", @"co.kr",
                                         @"com.sg", @"com.my", @"com.br", @"co.in"]];
    });
    NSString *last2 = [[parts subarrayWithRange:NSMakeRange(parts.count - 2, 2)]
                       componentsJoinedByString:@"."];
    if ([twoLevel containsObject:last2] && parts.count >= 3)
        return [[parts subarrayWithRange:NSMakeRange(parts.count - 3, 3)]
                componentsJoinedByString:@"."];
    return last2;
}

// 路径段泛化：数字 → \d+，长 token/UUID → 字符类，其余原样转义
static NSString *FCGeneralizeSegment(NSString *seg) {
    if (!seg.length) return @"";
    BOOL allDigit = YES;
    for (NSUInteger i = 0; i < seg.length; i++) {
        unichar c = [seg characterAtIndex:i];
        if (c < '0' || c > '9') { allDigit = NO; break; }
    }
    if (allDigit) return @"\\d+";

    if (seg.length >= 16) {
        BOOL hasDigit = NO, hasAlpha = NO, hexish = YES;
        for (NSUInteger i = 0; i < seg.length; i++) {
            unichar c = [seg characterAtIndex:i];
            if (c >= '0' && c <= '9') hasDigit = YES;
            else if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) hasAlpha = YES;
            BOOL isHex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') ||
                         (c >= 'A' && c <= 'F') || c == '-';
            if (!isHex) hexish = NO;
        }
        if (hexish && seg.length >= 32) return @"[0-9a-fA-F-]{16,}";
        if (hasDigit && hasAlpha) return @"[A-Za-z0-9_-]{8,}";
        if (seg.length >= 24) return @"[A-Za-z0-9_-]{8,}";
    }
    return FCReEscape(seg);
}

NSString *FCNetAutoPatternForURL(NSString *url) {
    if (!url.length) return @"";
    NSURLComponents *comp = [NSURLComponents componentsWithString:url];
    NSString *host = comp.host;
    NSString *path = comp.path;
    if (!host.length) {   // 兜底：URLComponents 解析不了就退化成整串转义
        NSURL *u = [NSURL URLWithString:url];
        host = u.host;
        path = u.path;
    }
    if (!host.length) return FCReEscape(url);

    NSMutableString *p = [NSMutableString stringWithString:@"https?://"];
    NSString *reg = FCRegistrableDomain(host);
    if (reg.length && ![reg isEqualToString:host.lowercaseString]) {
        [p appendString:@"([a-z0-9-]+\\.)*"];   // 子域泛化
    }
    [p appendString:FCReEscape(reg.length ? reg : host)];

    if (path.length && ![path isEqualToString:@"/"]) {
        for (NSString *s in [path componentsSeparatedByString:@"/"]) {
            if (!s.length) continue;
            [p appendFormat:@"/%@", FCGeneralizeSegment(s)];
        }
    } else {
        [p appendString:@"/?"];   // 根路径：允许带不带斜杠
    }
    return p;
}

BOOL FCNetPatternIsValid(NSString *pattern) {
    if (!pattern.length) return NO;
    NSError *err = nil;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern
                                        options:NSRegularExpressionCaseInsensitive error:&err];
    return re != nil && err == nil;
}

static NSRegularExpression *FCSafeRegex(NSString *pattern) {
    if (!pattern.length) return nil;
    return [NSRegularExpression regularExpressionWithPattern:pattern
        options:NSRegularExpressionCaseInsensitive error:nil];
}

NSUInteger FCNetPatternHitCount(NSString *pattern) {
    NSRegularExpression *re = FCSafeRegex(pattern);
    if (!re) return 0;
    NSUInteger n = 0;
    for (FCNetRecord *r in FCNetRecords()) {
        NSString *u = r.url;
        if (!u.length) continue;
        if ([re numberOfMatchesInString:u options:0 range:NSMakeRange(0, u.length)] > 0) n++;
    }
    return n;
}

NSArray<NSString *> *FCNetPatternHits(NSString *pattern) {
    NSRegularExpression *re = FCSafeRegex(pattern);
    if (!re) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (FCNetRecord *r in FCNetRecords()) {
        NSString *u = r.url;
        if (!u.length) continue;
        if ([re numberOfMatchesInString:u options:0 range:NSMakeRange(0, u.length)] > 0) {
            [out addObject:u];
            if (out.count >= 20) break;
        }
    }
    return out;
}

#pragma mark - 字段名 → 语义（驼峰切词，避开 download 里的 ad）

// isAd → [is, ad]；adInfo → [ad, info]；downloadUrl → [download, url]
// 这一步是整个打分的基础：不做切词，`download`/`head`/`shadow` 全会被当成广告。
static NSArray<NSString *> *FCWordsOfKey(NSString *key) {
    if (!key.length) return @[];
    NSMutableArray *out = [NSMutableArray array];
    NSMutableString *cur = [NSMutableString string];
    for (NSUInteger i = 0; i < key.length; i++) {
        unichar c = [key characterAtIndex:i];
        if (c == '_' || c == '-' || c == '.' || c == '/' || c == ':') {
            if (cur.length) [out addObject:cur.lowercaseString];
            [cur setString:@""];
            continue;
        }
        if (c >= 'A' && c <= 'Z' && cur.length) {
            [out addObject:cur.lowercaseString];
            [cur setString:@""];
        }
        [cur appendFormat:@"%C", c];
    }
    if (cur.length) [out addObject:cur.lowercaseString];
    return out;
}

static NSInteger FCAdScoreForKey(NSString *key) {
    NSInteger s = 0;
    for (NSString *w in FCWordsOfKey(key)) {
        if ([w isEqualToString:@"ad"] || [w isEqualToString:@"ads"] ||
            [w isEqualToString:@"advert"] || [w isEqualToString:@"adverts"] ||
            [w isEqualToString:@"advertise"] || [w isEqualToString:@"advertisement"]) { s += 3; continue; }
        if ([w isEqualToString:@"adinfo"] || [w isEqualToString:@"adlist"] || [w isEqualToString:@"adid"] ||
            [w isEqualToString:@"adtype"] || [w isEqualToString:@"adzone"] || [w isEqualToString:@"adslot"] ||
            [w isEqualToString:@"adunit"] || [w isEqualToString:@"promote"] || [w isEqualToString:@"promotion"] ||
            [w isEqualToString:@"sponsor"] || [w isEqualToString:@"commercial"] ||
            [w isEqualToString:@"ecpm"] || [w isEqualToString:@"impression"] ||
            [w isEqualToString:@"adcode"] || [w isEqualToString:@"admark"]) { s += 3; continue; }
        if ([w isEqualToString:@"banner"] || [w isEqualToString:@"splash"] ||
            [w isEqualToString:@"reward"] || [w isEqualToString:@"coupon"] ||
            [w isEqualToString:@"redpacket"] || [w isEqualToString:@"lottery"] ||
            [w isEqualToString:@"activity"] || [w isEqualToString:@"popup"] ||
            [w isEqualToString:@"market"] || [w isEqualToString:@"mall"] ||
            [w isEqualToString:@"track"] || [w isEqualToString:@"click"]) { s += 1; continue; }
    }
    return s;
}

#pragma mark - JSON 扁平化

// 输出元素：{ path, type, sample, score }
static void FCWalkJSON(id obj, NSString *prefix, NSMutableArray *out, int depth, int *budget) {
    if (*budget <= 0 || depth > 6 || !obj) return;
    *budget -= 1;

    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSArray *keys = [(NSDictionary *)obj allKeys];
        keys = [keys sortedArrayUsingSelector:@selector(compare:)];
        for (NSString *k in keys) {
            if (*budget <= 0) return;
            NSString *path = prefix.length ? [NSString stringWithFormat:@"%@.%@", prefix, k]
                                           : k;
            id v = obj[k];
            NSInteger sc = FCAdScoreForKey(k);
            if ([v isKindOfClass:[NSDictionary class]]) {
                [out addObject:@{@"path": path, @"type": @"对象", @"sample": @"{…}",
                                 @"key": k, @"score": @(sc)}];
                FCWalkJSON(v, path, out, depth + 1, budget);
            } else if ([v isKindOfClass:[NSArray class]]) {
                NSArray *arr = (NSArray *)v;
                [out addObject:@{@"path": path, @"type": @"数组",
                                 @"sample": [NSString stringWithFormat:@"%lu 项",
                                             (unsigned long)arr.count],
                                 @"key": k, @"score": @(sc)}];
                if (arr.count) FCWalkJSON(arr.firstObject, [path stringByAppendingString:@"[0]"],
                                          out, depth + 1, budget);
            } else {
                NSString *sample = [v description];
                if (sample.length > 60) sample = [[sample substringToIndex:60] stringByAppendingString:@"…"];
                [out addObject:@{@"path": path,
                                 @"type": [v isKindOfClass:[NSNumber class]] ? @"值" : @"文本",
                                 @"sample": sample, @"key": k, @"score": @(sc)}];
            }
        }
        return;
    }
    if ([obj isKindOfClass:[NSArray class]]) {
        NSArray *arr = (NSArray *)obj;
        if (arr.count) FCWalkJSON(arr.firstObject, [prefix stringByAppendingString:@"[0]"],
                                  out, depth + 1, budget);
    }
}

// 在原始 body 文本里截出「"key":值」这一整段——用于生成精确的 find 串。
// 规则引擎只做字面替换，所以必须拿到原文里真实的样子（含空格、引号）。
static NSString *FCSpanForKey(NSString *body, NSString *key) {
    if (!body.length || !key.length) return nil;
    NSString *needle = [NSString stringWithFormat:@"\"%@\"", key];
    NSRange r = [body rangeOfString:needle];
    if (r.location == NSNotFound) return nil;
    NSUInteger i = NSMaxRange(r);
    NSUInteger start = r.location;
    while (i < body.length) {
        unichar c = [body characterAtIndex:i];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') i++; else break;
    }
    if (i >= body.length || [body characterAtIndex:i] != ':') return nil;
    i++;
    while (i < body.length) {
        unichar c = [body characterAtIndex:i];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') i++; else break;
    }
    if (i >= body.length) return nil;

    unichar first = [body characterAtIndex:i];
    if (first == '"') {
        i++;
        while (i < body.length) {
            unichar c = [body characterAtIndex:i];
            if (c == '\\') { i += 2; continue; }
            i++;
            if (c == '"') break;
        }
    } else if (first == '[' || first == '{') {
        unichar open = first, close = (first == '[') ? ']' : '}';
        int depth = 0;
        while (i < body.length) {
            unichar c = [body characterAtIndex:i];
            if (c == '"') {
                i++;
                while (i < body.length) {
                    unichar d = [body characterAtIndex:i];
                    if (d == '\\') { i += 2; continue; }
                    i++;
                    if (d == '"') break;
                }
                continue;
            }
            if (c == open) depth++;
            else if (c == close) { depth--; if (depth == 0) { i++; break; } }
            i++;
        }
    } else {
        while (i < body.length) {
            unichar c = [body characterAtIndex:i];
            if (c == ',' || c == '}' || c == ']') break;
            i++;
        }
        while (i > start) {
            unichar c = [body characterAtIndex:i - 1];
            if (c == ' ' || c == '\n' || c == '\r' || c == '\t') i--; else break;
        }
    }
    if (i <= start) return nil;
    NSString *span = [body substringWithRange:NSMakeRange(start, i - start)];
    return span.length <= 400 ? span : nil;
}

#pragma mark - 分析结果对象

@implementation FCNetAnalysis
@end

#pragma mark - 主分析

FCNetAnalysis *FCNetAnalyzeRecord(FCNetRecord *rec) {
    FCNetAnalysis *a = [FCNetAnalysis new];
    a.highlights = @[];
    a.suggestedRules = @[];
    if (!rec) {
        a.report = @"(没有记录)";
        a.verdict = @"无数据";
        return a;
    }

    NSMutableString *rep = [NSMutableString string];
    NSMutableArray<NSString *> *hits = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *rules = [NSMutableArray array];
    NSInteger total = 0;

    NSString *pattern = FCNetAutoPatternForURL(rec.url);

    // ---------- 接口概要 ----------
    [rep appendString:@"▍接口\n"];
    [rep appendFormat:@"%@ %@\n", rec.method ?: @"?", rec.url ?: @"-"];
    [rep appendFormat:@"状态 %ld · 响应 %@ · %.0fms · 来源 %@\n",
     (long)rec.status,
     rec.respBody.length ? [NSString stringWithFormat:@"%.1fKB", rec.respBody.length / 1024.0] : @"-",
     rec.cost * 1000, rec.source ?: @"-"];
    if (rec.note.length) [rep appendFormat:@"标记 %@\n", rec.note];

    // ---------- 请求参数 ----------
    [rep appendString:@"\n▍请求参数\n"];
    NSURLComponents *comp = [NSURLComponents componentsWithString:rec.url ?: @""];
    NSArray<NSURLQueryItem *> *q = comp.queryItems;
    if (q.count) {
        NSMutableArray *kv = [NSMutableArray array];
        for (NSURLQueryItem *it in q) {
            [kv addObject:[NSString stringWithFormat:@"%@=%@", it.name, it.value ?: @""]];
        }
        [rep appendFormat:@"query %lu 项：%@\n", (unsigned long)q.count,
         [kv componentsJoinedByString:@", "]];
    } else {
        [rep appendString:@"query 无\n"];
    }
    if (rec.reqBody.length) {
        id jr = [NSJSONSerialization JSONObjectWithData:rec.reqBody options:0 error:nil];
        if ([jr isKindOfClass:[NSDictionary class]]) {
            NSArray *ks = [[(NSDictionary *)jr allKeys] sortedArrayUsingSelector:@selector(compare:)];
            [rep appendFormat:@"body(JSON) %lu 个字段：%@\n",
             (unsigned long)ks.count, [ks componentsJoinedByString:@", "]];
        } else {
            [rep appendFormat:@"body %lu 字节（非 JSON）\n", (unsigned long)rec.reqBody.length];
        }
    } else {
        [rep appendString:@"body 无\n"];
    }

    // ---------- 响应结构 ----------
    [rep appendString:@"\n▍响应结构\n"];
    id resp = rec.respBody.length
        ? [NSJSONSerialization JSONObjectWithData:rec.respBody options:0 error:nil] : nil;

    if ([resp isKindOfClass:[NSDictionary class]] || [resp isKindOfClass:[NSArray class]]) {
        NSMutableArray *flat = [NSMutableArray array];
        int budget = 300;
        FCWalkJSON(resp, @"", flat, 0, &budget);
        [rep appendFormat:@"JSON · %lu 个节点\n", (unsigned long)flat.count];

        for (NSDictionary *node in flat) {
            NSInteger sc = [node[@"score"] integerValue];
            NSString *line = [NSString stringWithFormat:@"  %@: %@%@\n",
                              node[@"path"], node[@"sample"],
                              sc >= 3 ? @"    ★广告特征" : (sc > 0 ? @"    ·可疑" : @"")];
            [rep appendString:line];
            if (sc >= 3) {
                total += sc;
                [hits addObject:[NSString stringWithFormat:@"%@ (+%ld)", node[@"path"], (long)sc]];
            } else if (sc > 0) {
                total += sc;
            }
        }

        // ---------- 建议：布尔字段 true → false ----------
        NSString *bodyText = [[NSString alloc] initWithData:rec.respBody encoding:NSUTF8StringEncoding];
        for (NSDictionary *node in flat) {
            NSInteger sc = [node[@"score"] integerValue];
            if (sc < 3) continue;
            NSString *key = node[@"key"];
            NSString *sample = node[@"sample"];
            NSString *type = node[@"type"];

            // 布尔 true —— 最常见的广告开关，直接改成 false
            if ([type isEqualToString:@"值"] && [sample isEqualToString:@"1"]) {
                NSString *span = FCSpanForKey(bodyText, key);
                if (span.length) {
                    NSRange cd = [span rangeOfString:@":"];
                    NSString *head = cd.location != NSNotFound
                        ? [span substringToIndex:cd.location] : nil;
                    if (head.length) {
                        [rules addObject:@{
                            @"name": [NSString stringWithFormat:@"%@ 置 false", key],
                            @"url": pattern ?: @"", @"method": @"*", @"enabled": @YES,
                            @"respBodyFind": span,
                            @"respBodyReplace": [head stringByAppendingString:@":false"],
                        }];
                    }
                }
            }
            // 数组 —— 置空。前提是原地文本不超过 400 字（否则会拖慢替换）
            if ([type isEqualToString:@"数组"]) {
                NSString *span = FCSpanForKey(bodyText, key);
                if (span.length && [span hasSuffix:@"]"]) {
                    NSString *repl = [NSString stringWithFormat:@"\"%@\":[]", key];
                    if (span.length > repl.length) {
                        [rules addObject:@{
                            @"name": [NSString stringWithFormat:@"%@ 清空", key],
                            @"url": pattern ?: @"", @"method": @"*", @"enabled": @YES,
                            @"respBodyFind": span, @"respBodyReplace": repl,
                        }];
                    }
                }
            }
        }
    } else if (rec.respBody.length) {
        [rep appendFormat:@"非 JSON（%lu 字节），结构分析跳过\n",
         (unsigned long)rec.respBody.length];
    } else {
        [rep appendString:@"无响应体（可能被 App 的 delegate 消费，或请求失败）\n"];
    }

    // ---------- 广告特征 ----------
    [rep appendString:@"\n▍广告特征\n"];
    NSInteger urlScore = FCAdScoreForKey(rec.url ?: @"");
    if (urlScore > 0) {
        total += urlScore;
        [hits addObject:[NSString stringWithFormat:@"URL 路径关键词 (+%ld)", (long)urlScore]];
    }
    if (hits.count) {
        [rep appendFormat:@"命中 %lu 处：%@\n", (unsigned long)hits.count,
         [hits componentsJoinedByString:@", "]];
    } else {
        [rep appendString:@"未发现明显的广告字段特征\n"];
    }

    if (total >= 9)      a.verdict = [NSString stringWithFormat:@"很可能是广告接口（%ld 分）", (long)total];
    else if (total >= 3) a.verdict = [NSString stringWithFormat:@"疑似含广告字段（%ld 分）", (long)total];
    else if (total > 0)  a.verdict = [NSString stringWithFormat:@"弱广告特征（%ld 分）", (long)total];
    else                 a.verdict = @"未发现广告特征";
    [rep appendFormat:@"判定：%@\n", a.verdict];

    // ---------- 兜底建议：阻断 ----------
    [rules addObject:@{
        @"name": @"阻断此接口",
        @"url": pattern ?: @"",
        @"method": rec.method.length ? rec.method : @"*",
        @"block": @YES, @"enabled": @YES,
    }];

    // ---------- 建议清单 ----------
    [rep appendString:@"\n▍建议动作\n"];
    if (rules.count == 1) {
        [rep appendString:@"（没找到可精确改写的开关，只剩阻断）\n"];
    }
    for (NSUInteger i = 0; i < rules.count; i++) {
        [rep appendFormat:@"%lu. %@\n", (unsigned long)(i + 1),
         FCNetRuleExplain(rules[i])];
    }
    if (pattern.length) {
        NSUInteger hit = FCNetPatternHitCount(pattern);
        [rep appendFormat:@"\n自动正则（当前命中 %lu 条记录）：\n%@\n",
         (unsigned long)hit, pattern];
    }

    a.report = rep;
    a.adScore = total;
    a.highlights = hits;
    a.suggestedRules = rules;
    return a;
}

#pragma mark - v55：全站一键分析

// 全站分析要遍历全部记录，可能有几百条。FCNetAnalyzeRecord 会拼整篇报告字符串，
// 逐条调用太重，所以这里单独一个「只算分 + 只产出规则」的轻量版：
// 不拼报告、JSON 节点预算 150、每个接口最多出 3 条规则。
#define FC_GLOBAL_MAX_SCORE_RECORDS   160   // 最多细算多少条请求（其余只按 URL 粗算）
#define FC_GLOBAL_MAX_RULES           12    // 一键处理最多加多少条规则
#define FC_GLOBAL_MAX_RULES_PER_GROUP 3

@implementation FCNetGroupStat
@end

@implementation FCNetGlobalAnalysis
@end

// 返回这条记录的广告特征分；同时把「能直接执行的规则」塞进 rulesOut、
// 把「为什么可疑」塞进 whyOut（都是人话，给不懂技术的人看）。
static NSInteger FCScoreRecordQuick(FCNetRecord *rec, NSString *pattern,
                                    NSMutableArray *rulesOut, NSMutableArray *whyOut) {
    NSInteger total = 0;

    NSInteger us = FCAdScoreForKey(rec.url ?: @"");
    if (us > 0) {
        total += us;
        if (whyOut) [whyOut addObject:@"网址里带广告词"];
    }

    if (!rec.respBody.length || !rec.respBody) return total;
    id resp = [NSJSONSerialization JSONObjectWithData:rec.respBody options:0 error:nil];
    if (![resp isKindOfClass:[NSDictionary class]] && ![resp isKindOfClass:[NSArray class]]) {
        return total;
    }

    NSMutableArray *flat = [NSMutableArray array];
    int budget = 150;
    FCWalkJSON(resp, @"", flat, 0, &budget);

    // 先累总分，再把「高分字段」挑出来。低分字段只贡献分数，不生成规则——
    // 给每个 banner 字段都写一条规则会把规则表塞满，反而让人看不懂。
    NSMutableArray *hot = [NSMutableArray array];
    for (NSDictionary *node in flat) {
        NSInteger sc = [node[@"score"] integerValue];
        if (sc <= 0) continue;
        total += sc;
        if (sc >= 3) [hot addObject:node];
    }
    if (!hot.count) return total;

    [hot sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSInteger x = [a[@"score"] integerValue];
        NSInteger y = [b[@"score"] integerValue];
        if (x == y) return NSOrderedSame;
        return (x > y) ? NSOrderedAscending : NSOrderedDescending;
    }];

    NSString *bodyText = [[NSString alloc] initWithData:rec.respBody encoding:NSUTF8StringEncoding];
    if (!bodyText.length) return total;

    NSMutableSet *done = [NSMutableSet set];
    NSUInteger made = 0;
    for (NSDictionary *node in hot) {
        if (made >= FC_GLOBAL_MAX_RULES_PER_GROUP) break;
        NSString *key = node[@"key"];
        NSString *type = node[@"type"];
        NSString *sample = node[@"sample"];
        if (!key.length || [done containsObject:key]) continue;
        [done addObject:key];

        // ① 开关类：原值是 true（JSON 里 NSNumber 的 description 是 "1"）
        if ([type isEqualToString:@"值"] && [sample isEqualToString:@"1"]) {
            NSString *span = FCSpanForKey(bodyText, key);
            if (!span.length) continue;
            NSRange cd = [span rangeOfString:@":"];
            if (cd.location == NSNotFound) continue;
            NSString *head = [span substringToIndex:cd.location];
            if (!head.length) continue;
            [rulesOut addObject:@{
                @"name": [NSString stringWithFormat:@"%@ 关掉", key],
                @"url": pattern ?: @"", @"method": @"*", @"enabled": @YES,
                @"respBodyFind": span,
                @"respBodyReplace": [head stringByAppendingString:@":false"],
            }];
            if (whyOut) [whyOut addObject:[NSString stringWithFormat:@"%@ 是开着的", key]];
            made++;
            continue;
        }
        // ② 列表类：整段置空 —— 广告内容基本都在这种数组里
        if ([type isEqualToString:@"数组"]) {
            NSString *span = FCSpanForKey(bodyText, key);
            if (!span.length || ![span hasSuffix:@"]"]) continue;
            NSString *repl = [NSString stringWithFormat:@"\"%@\":[]", key];
            if (span.length <= repl.length) continue;
            [rulesOut addObject:@{
                @"name": [NSString stringWithFormat:@"%@ 清空", key],
                @"url": pattern ?: @"", @"method": @"*", @"enabled": @YES,
                @"respBodyFind": span, @"respBodyReplace": repl,
            }];
            if (whyOut) [whyOut addObject:[NSString stringWithFormat:@"%@ 里有内容", key]];
            made++;
        }
    }
    return total;
}

FCNetGlobalAnalysis *FCNetAnalyzeAllRecords(void) {
    FCNetGlobalAnalysis *g = [FCNetGlobalAnalysis new];
    g.groups = @[];
    g.rules = @[];

    NSArray<FCNetRecord *> *recs = FCNetRecords();
    g.recordCount = recs.count;
    if (!recs.count) {
        g.verdict = @"还没抓到数据";
        g.report = @"▍还没有记录\n"
                    @"① 确认上面是「采集：开」\n"
                    @"② 回 App 点几下、下拉刷新\n"
                    @"③ 再点这个按钮\n\n"
                    @"只记录接口请求，图片/视频不算。";
        return g;
    }

    // ---------- 按「接口族」归组 ----------
    // 归组用的是自动泛化正则，所以 /ad/list?ts=1 和 /ad/list?ts=2 会落到同一族，
    // 不会出现「同一个接口在列表里算成十个」的情况。
    NSMutableDictionary<NSString *, NSMutableArray *> *byKey = [NSMutableDictionary dictionary];
    for (FCNetRecord *r in recs) {
        NSString *p = FCNetAutoPatternForURL(r.url ?: @"");
        if (!p.length) p = r.url.length ? r.url : @"(无法解析)";
        NSMutableArray *arr = byKey[p];
        if (!arr) { arr = [NSMutableArray array]; byKey[p] = arr; }
        [arr addObject:r];
    }
    g.groupCount = byKey.count;

    // ---------- 每个族挑「最能说明问题」的一条细算 ----------
    NSMutableArray<FCNetGroupStat *> *stats = [NSMutableArray array];
    NSUInteger scored = 0;
    for (NSString *p in byKey) {
        NSArray<FCNetRecord *> *arr = byKey[p];
        FCNetGroupStat *best = nil;
        for (FCNetRecord *r in arr) {
            if (scored >= FC_GLOBAL_MAX_SCORE_RECORDS) break;
            scored++;
            NSMutableArray *rr = [NSMutableArray array];
            NSMutableArray *why = [NSMutableArray array];
            NSInteger s = FCScoreRecordQuick(r, p, rr, why);
            if (!best || s > best.score) {
                FCNetGroupStat *st = [FCNetGroupStat new];
                st.pattern = p;
                st.sample = r.url ?: @"";
                st.hits = arr.count;
                st.score = s;
                st.rules = rr;
                st.why = [why componentsJoinedByString:@"、"];
                best = st;
            }
        }
        if (best) [stats addObject:best];
    }

    [stats sortUsingComparator:^NSComparisonResult(FCNetGroupStat *a, FCNetGroupStat *b) {
        if (a.score != b.score) return (a.score > b.score) ? NSOrderedAscending : NSOrderedDescending;
        if (a.hits != b.hits) return (a.hits > b.hits) ? NSOrderedAscending : NSOrderedDescending;
        return NSOrderedSame;
    }];
    g.groups = stats;

    // ---------- 汇总建议（去重 + 限量，且永不含阻断） ----------
    NSMutableArray<NSDictionary *> *rules = [NSMutableArray array];
    NSMutableSet *sig = [NSMutableSet set];
    NSUInteger suspects = 0;
    for (FCNetGroupStat *st in stats) {
        if (st.score >= 3) suspects++;
        if (st.score <= 0) continue;
        for (NSDictionary *r in st.rules) {
            if (rules.count >= FC_GLOBAL_MAX_RULES) break;
            NSString *s = [NSString stringWithFormat:@"%@|%@|%@",
                           r[@"url"] ?: @"", r[@"respBodyFind"] ?: @"", r[@"name"] ?: @""];
            if ([sig containsObject:s]) continue;
            [sig addObject:s];
            [rules addObject:r];
        }
        if (rules.count >= FC_GLOBAL_MAX_RULES) break;
    }
    g.rules = rules;
    g.suspectCount = suspects;

    // ---------- 写报告 ----------
    // v56：老大要求「精简说明文字」。原来一段「三种原因」占 4 行、三步走占 4 行，
    // 手机上要滑三屏才看得完。现在压到：结论 1~2 行、可疑条目 2~3 行、下一步 3 行。
    NSMutableString *rep = [NSMutableString string];
    [rep appendString:@"▍结论\n"];
    if (!rules.count) {
        g.verdict = @"没找到能自动关的广告开关";
        [rep appendFormat:@"%lu 条请求 / %lu 个接口 · 可自动改 0 处\n",
         (unsigned long)g.recordCount, (unsigned long)g.groupCount];
        [rep appendString:@"原因：广告还没刷出来，或广告不在接口里（图片/视频）。\n"];
    } else {
        g.verdict = [NSString stringWithFormat:@"%lu 个可疑接口 · 可关 %lu 处",
                     (unsigned long)suspects, (unsigned long)rules.count];
        [rep appendFormat:@"%lu 条请求 / %lu 个接口\n",
         (unsigned long)g.recordCount, (unsigned long)g.groupCount];
        [rep appendFormat:@"可疑接口 %lu 个 · 可自动关 %lu 处（红色是可疑的）\n",
         (unsigned long)suspects, (unsigned long)rules.count];
    }

    // 最可疑的 5 个
    [rep appendString:@"\n▍最可疑\n"];
    NSUInteger shown = 0;
    for (FCNetGroupStat *st in stats) {
        if (st.score <= 0 || shown >= 5) break;
        shown++;
        NSString *u = st.sample;
        if (u.length > 78) u = [[u substringToIndex:78] stringByAppendingString:@"…"];
        [rep appendFormat:@"%ld分 ×%lu  %@\n", (long)st.score, (unsigned long)st.hits, u];
        if (st.why.length) [rep appendFormat:@"  ↳ %@\n", st.why];
        if (st.rules.count) {
            NSMutableArray *names = [NSMutableArray array];
            for (NSDictionary *r in st.rules) {
                NSString *n = r[@"name"];
                if (n.length) [names addObject:n];
            }
            if (names.count) {
                [rep appendFormat:@"  ↳ 可改：%@\n", [names componentsJoinedByString:@" / "]];
            }
        }
    }
    if (!shown) [rep appendString:@"没有分数为正的接口\n"];

    // 下一步
    [rep appendString:@"\n▍下一步\n"];
    if (rules.count) {
        [rep appendFormat:@"1 点右上「一键处理」→ 关掉 %lu 处\n",
         (unsigned long)rules.count];
        [rep appendString:@"2 回 App 下拉刷新看效果\n"
                       @"3 还有广告 → 再来一次；误伤 → 规则里删掉\n"];
    } else {
        [rep appendString:@"1 回 App 把广告刷出来（多点几个页面）\n"
                       @"2 回来再点「一键分析」\n"];
    }
    [rep appendString:@"不断接口（会白屏），要断请进单条详情手动加。\n"];

    // 排行
    [rep appendString:@"\n▍接口排行\n"];
    NSUInteger rank = 0;
    for (FCNetGroupStat *st in stats) {
        if (rank >= 20) break;
        rank++;
        NSString *u = st.sample ?: @"";
        NSURLComponents *c = [NSURLComponents componentsWithString:u];
        NSString *shortU = u;
        if (c.host.length) {
            shortU = [NSString stringWithFormat:@"%@%@", c.host, c.path ?: @"/"];
        }
        if (shortU.length > 46) shortU = [[shortU substringToIndex:46] stringByAppendingString:@"…"];
        [rep appendFormat:@"%3ld ×%-3lu %@\n", (long)st.score, (unsigned long)st.hits, shortU];
    }
    if (stats.count > 20) {
        [rep appendFormat:@"…另有 %lu 个接口（都在 %ld 分以下）\n",
         (unsigned long)(stats.count - 20), (long)(stats.count ? stats[19].score : 0)];
    }
    if (scored >= FC_GLOBAL_MAX_SCORE_RECORDS) {
        [rep appendFormat:@"（只细算了前 %lu 条请求）\n",
         (unsigned long)FC_GLOBAL_MAX_SCORE_RECORDS];
    }

    g.report = rep;
    return g;
}

NSInteger FCNetUrlSuspectScore(NSString *url) {
    if (!url.length) return 0;
    return FCAdScoreForKey(url);
}

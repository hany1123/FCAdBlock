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
    [rep appendString:@"===== 接口 =====\n"];
    [rep appendFormat:@"%@ %@\n", rec.method ?: @"?", rec.url ?: @"-"];
    [rep appendFormat:@"状态 %ld · 响应 %@ · %.0fms · 来源 %@\n",
     (long)rec.status,
     rec.respBody.length ? [NSString stringWithFormat:@"%.1fKB", rec.respBody.length / 1024.0] : @"-",
     rec.cost * 1000, rec.source ?: @"-"];
    if (rec.note.length) [rep appendFormat:@"标记 %@\n", rec.note];

    // ---------- 请求参数 ----------
    [rep appendString:@"\n===== 请求参数 =====\n"];
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
    [rep appendString:@"\n===== 响应结构 =====\n"];
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
    [rep appendString:@"\n===== 广告特征 =====\n"];
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
    [rep appendFormat:@"判定：**%@**\n", a.verdict];

    // ---------- 兜底建议：阻断 ----------
    [rules addObject:@{
        @"name": @"阻断此接口",
        @"url": pattern ?: @"",
        @"method": rec.method.length ? rec.method : @"*",
        @"block": @YES, @"enabled": @YES,
    }];

    // ---------- 建议清单 ----------
    [rep appendString:@"\n===== 建议动作 =====\n"];
    if (rules.count == 1) {
        [rep appendString:@"（只有「阻断」这一条。响应体里没有找到可精确改写的字段——\n"
                       @"  布尔开关/广告数组都没有，说明这条接口的数据结构不直接暴露广告标记。）\n"];
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

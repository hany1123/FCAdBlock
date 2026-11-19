//
//  FCNet.h —— 进程内网络取证 / 重写 / 拦截（v52）
//
//  为什么能在进程内看到明文：dylib 注入在目标 App 的进程里，TLS 早就在这个进程内解完了，
// 我们看到的是「解密之后、加密之前」的数据。所以不需要装证书、不需要代理，
// 天然不受 SSL Pinning 影响（Pinning 校验的是远端链，跟本地明文无关）。
//
//  三层采集：
//    ① NSURLProtocol 接管（FCNetProtocol）：能改请求、能造 mock 响应、能阻断。
//       这是唯一能「改写」的一层，也是本模块的主力。
//    ② Deep 档额外 hook NSURLSession 的 task 创建与 delegate/completion：
//       只读采集，用于补上「走 delegate 而不是 completionHandler」的请求。
//    ③ NSURLConnection 老接口：只读，现在几乎见不到，留个兜底位置。
//
//  Pure 档说明：①是注册 NSURLProtocol（合法 API，不是 hook，nm -u 里不会出现
//  method_setImplementation），所以 Pure 档也有完整的采集/重写/拦截能力；
//  只有②要 hook 系统类，严格放在 #ifdef FC_DEEP_HOOKS 内。
//
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// 一条网络记录。body 可能是二进制，为了 UI 与内存都安全，这里只存「裁剪后的副本」。
@interface FCNetRecord : NSObject
@property (nonatomic, assign) NSUInteger rid;
@property (nonatomic, strong) NSDate *date;
@property (nonatomic, copy)   NSString *method;
@property (nonatomic, copy)   NSString *url;
@property (nonatomic, copy)   NSString *host;
@property (nonatomic, copy)   NSString *path;
@property (nonatomic, strong, nullable) NSDictionary<NSString *, NSString *> *reqHeaders;
@property (nonatomic, strong, nullable) NSData *reqBody;
@property (nonatomic, assign) NSInteger status;
@property (nonatomic, strong, nullable) NSDictionary<NSString *, NSString *> *respHeaders;
@property (nonatomic, strong, nullable) NSData *respBody;
@property (nonatomic, assign) NSTimeInterval cost;      // 秒
@property (nonatomic, copy)   NSString *source;         // 协议/会话/连接
@property (nonatomic, copy, nullable) NSString *note;   // 被哪条规则改过 / 被拦
@property (nonatomic, assign) BOOL failed;
@property (nonatomic, copy, nullable) NSString *errText;
@end

// 采集开关（会同时决定 NSURLProtocol 是否接管）
void FCNetSetEnabled(BOOL on);
BOOL FCNetEnabled(void);

// 采集记录（最近 N 条，环形）
NSArray<FCNetRecord *> *FCNetRecords(void);
NSUInteger FCNetRecordCount(void);
void FCNetClearRecords(void);

// 面板
void FCNetShowPanel(void);
void FCNetHidePanel(void);
BOOL FCNetPanelVisible(void);
void FCNetRefreshPanelIfVisible(void);

// 重写 / 拦截规则：数组元素是 NSDictionary，结构见 FCNetRuleExplain()
NSArray<NSDictionary *> *FCNetRules(void);
void FCNetSetRules(NSArray<NSDictionary *> *_Nullable rules);
void FCNetAddRule(NSDictionary *rule);
void FCNetRemoveRuleAtIndex(NSUInteger idx);
NSString *FCNetRuleExplain(NSDictionary *rule);   // 一行中文描述，给 UI 用

// 给主模块用的：把抓到的请求做成「元素隐藏规则」的辅助（域名+路径）
NSString * _Nullable FCNetSuggestedRuleForRecord(FCNetRecord *rec);

// 启动时调一次：恢复开关状态、装好 NSURLProtocol
void FCNetBootstrap(void);

NS_ASSUME_NONNULL_END

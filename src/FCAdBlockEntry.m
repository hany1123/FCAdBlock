//
//  FCAdBlockEntry.m —— 通用去广告插件 v45（丰巢 HiveConsumer + 淘宝 Taobao4iPhone）
//
//  v45 相对 v44（老大 v44 真机：还是那句「这个领券中心总是去不掉」，附诊断 + 截图）：
//    【现场】我的淘宝页：规则 5 条（全是首页模板/文字）、被挡节点 0、压0 容器 0、留白 0pt，
//    目标 `MTDinamicXCell | 0,501 430x142 | 压:否 tpl:- 拦:否`；坐标反查外层是
//    `UITableViewCellContentView` → **它是 UITableView 的一行**；浮标却写着
//    「是键盘容器(UIInputSetContainerView)，请点广告内容区」。
//    【根因一·点了白点】`FCHitViewAtPoint` 遍历所有窗口、后遍历到的窗口会覆盖前面的结果，
//    键盘/输入窗口里看不见的 `UIInputSetContainerView` 把命中抢走 → 点选在入口就被劝退
//    （那条 return 在 `FCPickNative` 最前面）。扫描侧早就跳过这些窗口，点选侧漏了同一个过滤。
//    修：点选侧整窗跳过 UITextEffects/UIRemoteKeyboard/_UI/含 Input|Keyboard 的窗口。
//    【根因二·就算命中也会被免压跳过】目标 142pt > 阈值 120pt，而「大块免压」是开着的 →
//    四个压0 入口一律 continue。免压的本意是「别制造大留白」，但表格行可以真归零、不会留白，
//    于是新增 `FCRowZeroCapable`：能归零的行不受免压限制。
//    【根因三·压了也是白块】压0 只把内容藏起来，行高 142pt 由 UITableView 决定，位置还在。
//    修：新增「行高归零」（Deep 档）——接管表格 delegate 的
//    `tableView:heightForRowAtIndexPath:` / `estimatedHeightForRowAtIndexPath:`，
//    只对自己点名登记过的行返回 0，其它行原样交给原实现；每轮校验行号归属，换人就撤销。
//    【配套】命中点落在表格行里时，压0 目标与点选目标都**升级到整行**（守卫：行高≤45%屏、
//    有效文字≤12 条），这样「压的是行、归零的也是行」，不会出现「文字没了、行还在」。
//
//  v44 相对 v43（老大 v43 真机：「我的淘宝」里「超级88领券中心」怎么点都去不掉）：
//    【现场】规则 5 条、压0 12 个、留白 466pt，目标卡片 `MTDinamicXCell 0,501 430x142`
//    诊断里是 `压:否 tpl:- 拦:否`——没有任何规则认领它，而且规则列表里也没有它的指纹。
//    【根因一·点选直接被劝退】`FCPickNative` 里 `fromWeb && trulyH5` 一成立就 `return`，
//    只弹一句「网页拾取失败」。而这块卡片的引擎被判定成 H5（页面有满屏空壳 WKWebView 干扰），
//    于是**一条 cls:/pos: 规则都没存下来**，用户点多少次都是白点。
//    修：H5 判定时不再中断——仍然不隐藏（隐藏等于藏整个网页），但 cls:/pos: 指纹照存，
//    交给扫描阶段的几何匹配去认领；提示也从「失败」改成「判定H5·已记N类+位置(不回退隐藏)」。
//    【根因二·满宽卡片永远存不了 pos:】原门槛要求「宽 <90%屏 **且** 高 <90%屏」，
//    可淘宝运营位几乎都满宽（430/430=100%），于是所有满宽卡片都被拒绝。
//    修：与 `FCIsUnsafeClassRule` 对齐——危险条件是「宽≥90% 且 高≥90%」**同时**成立
//    （那才是页面根容器的特征），只满足一个是正常卡片，允许保存。
//    【顺手修】大块免压开关打开后，把「已经压掉的」大位还原——否则开关只对新命中生效，
//    之前压的 155pt 大位照样留着白，等于没开。还原在 `FCReapplyAllZeroFrames` 开头做一次，
//    并且四个压0 入口都已带 `FCShouldSkipBigBlock` 判断，不会压回去造成抖动。
//
//  v43 相对 v42（老大 v42 真机：点选能用了、挡的数字也不再涨，但首页顶部出现 ~580pt 大白块）：
//    【现象】浮标 `规则9 挡0 压33`，首页 tab 栏以下到商品流之间整片空白。
//    【根因】不是回归 bug，是「压0 只让内容消失、不减坑位高度」这条硬约束在规则变多后被放大：
//    9 条规则里有 4 条压的是大运营位（gongge 四宫格 155pt、88 活动卡 135pt×2、直播卡 155pt），
//    每压一块就留一块等高空白，叠起来正好 ~580pt。
//    【修法·三项，都不动布局层】
//      ① 规则质量门槛 FCRuleIsJunk：拒绝点选误触产生的垃圾规则——含逗号/顿号/竖线的复合串
//        （真机「猜你喜欢,已选中」= tab 标题+状态词被拼成一串）、纯状态词（待使用/返回顶部/
//        已选中/去使用…）。这类规则拦不到广告，只会误伤含相同字串的正常容器。
//      ② 留白可见化：`FCWhiteSpaceEstimate()` 按「其祖先无压0记录」去重累加被压坑位高度，
//        浮标直接显示 `白~580pt`，诊断新增 `[留白] 合计 Npt（约 X% 屏高）` 与每条
//        `[压0清单] … 留白155pt 父=Cls`——压哪条值不值，一眼可判。
//      ③ 大块免压开关（持久化 `FCAdBlockBigBlockPass_v1`，默认关）：打开后高度 >120pt 的
//        运营位在四个入口（用户规则 / 源头模板 / 外壳 cell / 轮播空壳）一律跳过，
//        小广告（商品流推广卡 60~100pt）照常压，几乎不留白。
//    【已知边界】压0 无法真正减高度：UICollectionView 的 item 高度由 layout/dataSource 给，
//    改子视图 frame 不影响它。要根治只能在宿主布局层动手（hook 系统布局类违反本工程铁律，
//    故不做）。当前策略是「压得准、留白看得见、大块可跳过」。
//
//  v42 相对 v41（老大 v41 真机：不闪退了、白块也没了，但**无法选择广告元素**，且
//  浮标上「挡」的数字一直往上涨）：
//    【问题1 · 数字一直涨】v12 加的 gFCBuiltinBlocked 是「命中却被尺寸闸门挡下的**次数**」，
//    每轮扫描遍历到同一节点就再 +1，真机 978 看着像挡了上千个广告，其实只有几个节点。
//    修：加弱表 gFCBlockedSeen 按节点只计一次，新增 gFCBlockedUnique 表示「被挡节点数」；
//    浮标/诊断显示去重数，动作轮次另列。数字从此稳定，不再每 tick 往上涨。
//    【问题2 · 选不中广告元素】根因是「自己把想选的广告压成 0 了」——那一片是空白，
//    hitTest 够不着内容，点下去只能命中外层容器；再加上淘宝首页满屏空壳 WKWebView
//    (frame 0,0 430x932 DOM空) 会抢命中，v24 的穿透只认 DX/RN/Flutter/小程序四种引擎，
//    兜不住纯 UIKit 运营位 → 走网页通道 → 报「网页拾取失败」。
//    修：①**点选进入即临时还原全部拦截并冻结扫描**（FCRestoreAllBlockedForPicking +
//    gFCPickFreeze），退出点选解冻、按最新规则重新拦——这是「选得到」的根本前提；
//    ②穿透放宽为两档：引擎宿主优先，兜底取同坐标下非 WK、非系统私有、尺寸真实的
//    最深业务 view；③菜单新增「暂停拦截（恢复原样·用于点选）」——DX 已渲染过的卡片
//    光还原 frame 不会自动重新 setData，下拉刷新一次才真的回来，这个开关是兜底路径；
//    ④还原时连实例级 kFCBlockedRoot 标记一起清（弱表 gFCBlockedRoots 登记过），
//    否则 setData hook 看到旧标记继续 return，还原了也是空白。
//    【安全】暂停/冻结只作用于本插件自己的行为，不 hook 任何新系统方法；两档残留都会在
//    退出点选/恢复拦截后由常规扫描重新建立，无需重启进程。
//
//  v41 相对 v40（老大 v40 真机：注入后淘宝**闪退**，.ips 已定位到本插件）：
//    【崩溃铁证】Taobao4iPhone-2026-11-19-002646.ips：EXC_BAD_ACCESS(SIGSEGV)
//    KERN_INVALID_ADDRESS at 0x3fffffff，faultingThread = com.apple.uikit.datasource.diffing，
//    栈为 [objc_retain + 8] ← [FCAdBlock_Deep_v40 + 0x182EC] ← [initializeRootView + 316]
//    ← cellForItemAtIndexPath ← _createAndAppendViewAnimationsForInserts ← performBatchUpdates。
//    反汇编核对：0x182EC 正是 FCHookSetHeightSpec 里 objc_getAssociatedObject 之后那条
//    objc_retainAutoreleasedReturnValue（stub 0x1951c/0x19594 已按 indirect symtab 验证）。
//    【根因】v40 在被拦实例的 setter 里**同步**调 invalidateLayout/beginUpdates-endUpdates。
//    diffable data source 正在做 insert 动画、预取 cell 的过程中重入布局，正在初始化的
//    DXRootView 被提前释放 → initializeRootView 拿着野指针继续调 setOriginalHeightSpec:
//    → hook 第一行读关联对象就把垃圾指针交给 ARC retain → 崩。另外 FCZeroDXHeightSpec 用
//    valueForKey: 读 originalHeightSpec 旧值，在半初始化对象上同样会拿到垃圾指针（同类风险）。
//    【修法】① 重排改为「弱引用入队 FCEnqueueRelayout」+「扫描 tick 里 FCPerformPendingRelayout
//    统一执行」，hook 内绝不再同步重排；② 高度规格改「只写不读」，直接 objc_msgSend setter @0，
//    不再 KVC 读旧值；③ hook 内不再对 spec 做 FCProbeRecord/[description] 内省；④ 加重入闸。
//    例行 __fcadVer 40→41。
//
//  v40 相对 v39（老大 v39 真机：浮标 FCv39 压3→压15，但白块不但没消、反而更大——天猫图标和
//  淘宝秒杀卡也一起没了，商品流起点仍在 y≈590）：
//    【决定性铁证】把 v35 与 v39 两张截图并排：中间那段区域高度两版都是 ≈480pt，商品流第一行
//    都在 y≈590（占屏63%）。压掉 12 个东西，高度一毫米没减 → **压内部子视图只删内容、不减高度**。
//    这才是 v32~v39 八版打不动的真正原因：方向错了，不是判据不够准。
//    【v39 另一处死因】去类名闸门后函数内第一道排除是 hasPrefix:@"UI" —— 而目标恰恰是 UIView。
//    诊断里三层 UIView 全「压:否」就是它挡的。
//    【修法·从布局源头减高度】新增 FCZeroDXHeightSpec：把被拦 DXRootView 的 originalHeightSpec
//    置 0；同时 hook setOriginalHeightSpec:，让任何来源设的高度都被强制归零；再调
//    FCTriggerHostRelayout 让最近的 UICollectionView/UITableView invalidateLayout 重排。
//    安全边界：只在 spec 是 NSNumber 时改写，自定义 spec 对象只记日志不硬塞（绝不搞崩引擎）。
//    v39 的几何空壳调用停用（代码保留便于回退）。诊断新增 [高度归零]/[高度归属] 两段取证。
//    例行 __fcadVer 39→40。
//
//  v39 相对 v38（老大 v38 真机：白块仍在，浮标「规则3 内0 挡0 原3 压3」——压3全是老逻辑，v38 塌陷零触发）：
//    【v38 失败根因】v38 把几何判据套在 AliIFDXCollectionViewCell 类名闸门后，但真机撑白块的外层
//    容器类名又漂移了——坐标反查抓到 0,143 430x86 是普通 UIView + DXRootView(tpl:slider_icons)、
//    0,236 430x155 / 0,400 430x135 是普通 UIView（内部 gongge/88_campaign 的 DXRootView 已被压0）。
//    一个都不是 AliIFDXCollectionViewCell → 类名闸门把所有目标挡在门外，几何判据再对也没机会执行。
//    【三次真机类名漂移】v36/37 = AliIFDXCollectionViewCell → v38/39 = UIView / DXRootView，
//    证明「靠类名认领」此路不通。
//    【修法·去类名闸门】FCZeroRotorCellIfEmpty 对扫描到的所有容器统一跑几何+可见文字判据：
//    满宽≥75%屏 + 高60~170(覆盖86/135/155三层) + 屏幕y100~450 + 有效可见文字≤1；
//    内加系统容器/Scroll/tabbar 排除 + 已认领幂等。gongge/88 外壳的「文3」是内部 kFCZeroRec
//    压0节点的假文字，FCCellLiveTextCount 整枝跳过后数成0 → 正确认领；秒杀卡片(真文4~5)/商品流不误伤。
//    自愈仍用 FCPruneRotorCells 同源口径（离树或子树冒出>1条正常文字才还原）。例行 __fcadVer 38→39。
//
//  v38 相对 v37（老大 v37 真机：商品流防误伤成功，但白块塌陷一次没触发——浮标「内0 挡0 压68」、
//  白块 cell 仍「压:否 tpl:- 拦:否」）：
//    【v37 失败根因·三条交叉】①v37 只从「带源头痕迹的 DXRootView」向上找 cell，但真正白块
//    AliIFDXCollectionViewCell 0,143 430x86 上 tpl:- 拦:否、内部无源头痕迹，触发链根本走不到；
//    ②压0清单证明里面被压的 132x155 卡片是用户文字规则(kFCZeroRec)压的，v37 口径不认；
//    ③白块候选判据 height≥120 把 86pt 轮播位天然排除，反而报了带正常商品的 430x155 秒杀卡片。
//    【精准修法·几何判据认领】新增 FCZeroRotorCellIfEmpty：扫描阶段直接对 AliIFDXCollectionViewCell
//    按四重判据认领——满宽≥75%屏 + 高60~120(覆盖86、排除155秒杀) + 屏幕y100~300(搜索栏下轮播区、
//    排除y400+商品流) + 有效可见文字≤1(秒杀卡片文4~5被挡)。留树重压、独立 gFRotorZeroed 表。
//    【专属自愈口径】v37 的「源头痕迹消失才还原」对无痕迹的轮播位会刚压就还原，故 v38 另立
//    FCPruneRotorCells：cell 离树或子树冒出>1条正常文字才还原；配 FCCellSubtreeLiveText 专计数子树
//    （绕开 cell 自身 kFCZeroRec 导致 FCCellLiveTextCount 首行返回0的坑）。例行 __fcadVer 37→38。
//
//  v37 相对 v36（老大 v36 诊断三修后带回决定性证据——白块真凶第一次锁死）：
//    【交叉印证】v36 [白块候选] AliIFDXCollectionViewCell 0,400 430x135（压:否 tpl:-）
//    与 [压0清单·源] DXRootView 原0,0 430x135→0x0（88_campaign）尺寸完全吻合=同一坑位内外两层；
//    坐标反查采样点覆盖的最内层也全是这个 cell。根因定案：源头拦/压0只作用于内部 DXRootView，
//    外层 AliIFDXCollectionViewCell 仍占满宽高度=白块。second_pit/campaign_bottom_bar 走 hook
//    return、连压0表都不进，同样留空壳 cell。
//    【精准修法·不误伤商品流】新增 FCZeroBlockedCellShell：扫描阶段从「带 kFCBlockedRoot /
//    bridge模板命中」的 DXRootView 向上最多4层找 AliIFDXCollectionViewCell，满宽+高80~32%屏+
//    无有效内容(≤2文字)才压0外壳(留树重压,独立gFCShellZeroed表)；商品流 recommend_* 无源头
//    痕迹、根本不触发。FCPruneBlockedCellShells 每轮自愈：cell离树/内部痕迹消失(模板复用成正常
//    卡片)即还原。kFCBlockedRoot 前移到全局区供扫描阶段读取。
//    例行 __fcadVer 36→37。
//
//  v36 相对 v35（老大 v35 同页真机：截图+诊断都在首页推荐tab——[源头拦截]secondfloor_10
//    首次命中，但搜索栏下白块仍在（天猫入口+淘宝秒杀卡片还在）；且诊断[白块候选]报「无」
//    与截图白块矛盾——诊断判据把自己过滤瞎了）：
//    【诊断三修·不改任何拦截/压0逻辑，零功能风险】老大选「修诊断再精准打」：
//    ①放宽 FCAppendBlankContainerDiag：UIScrollView/UICollectionView/UITableView 不再排除、
//      子树文字阈值 2→8（白块右侧秒杀卡片多文字被挡）、已压0容器也列出并标 originalFrame；
//    ②新增 FCAppendCoordinateProbe：对白块采样点(x中心,y=200/350/500)遍历全树，
//      列覆盖它的大容器(面积小→大),类名+frame+压0+alpha+模板名——按坐标抓无文字大容器；
//    ③新增 FCAppendZeroedList：列所有高度≥100的压0记录 originalFrame→当前frame，
//      专抓「压0后 DX 重设 frame 回来」撑白块那层。
//    ④修误导提示：深扫未捕获secondfloor=源头拦截生效(正常)，不再提示进「我的淘宝」页。
//    例行 __fcadVer 35→36。
//
//  v35 相对 v34（老大 v34 真机：second_pit 源头拦截命中+源头压0容器4个，但首页
//    搜索栏下白块仍在，天猫入口+轮播点还在——被压的4个容器都不含白块主体）：
//    【白块真凶修正】v34 误判「secondfloor 是首页信息流容器、拦了会整页空白」，
//    实际 golden 取证：商品信息流是 recommend_* 系列（recommend_m_home_*/
//    recommend_newface_*），secondfloor（secondfloor_10/secondfloor.zip,columnType=one）
//    是独立的搜索栏下运营楼层。老大授权「拦+压，天猫入口一起去掉」。
//    改：①内置身份表加 secondfloor 子串（拦内容+FCZeroSourceRoot 压容器，商品流不碰）；
//    ②诊断加「白块候选容器」只读段（宽≥90%屏/高150~600/无文字大容器，列类名+frame+
//    bridge模板名+是否命中拦截），若 v35 仍未消白块，一段定位真凶不再猜容器层级。
//    例行 __fcadVer 34→35。
//
//  v34 相对 v33（老大 v33 真机：88横幅已消失=源头拦截生效；只剩搜索栏下方大白块，
//    压0从42暴涨到101仍压不掉）：
//    【白块真因】它是 second_pit_searchbar_slim 运营坑位（轮播+天猫入口，约半屏），
//    既不在内置拦截表、用户也没加 tpl: 规则；内容文字被压0后，承载它的 DXRootView
//    容器仍占着 frame → 空壳留白。空壳清理的 45%屏闸门+非空壳判定都够不到它。
//    改：①内置身份表加「second_pit」子串（绝不写 secondfloor——那是信息流容器，
//    拦了整页空白）；②扫描阶段按 bridge 模板映射找到命中的 DXRootView 容器，
//    FCZeroSourceRoot 把它压0（独立 gFCSourceZeroed 表 + 每轮重压），命中即拦内容、
//    容器也塌；③FCPruneSourceZeros 每轮自愈——容器离树/模板被复用成正常卡片时还原，
//    防误伤。例行 __fcadVer 33→34。
//
//  v33 相对 v32（老大 v32 真机：压0生效42个/重压81次，但大白块与88横幅仍在）：
//    【两处根因——源码+真机取证交叉锁定，非猜】
//    ①大白块：FCRemoveEmptyShellIfNeeded 只查直接父一层 + 高度上限 30%屏；真机
//      secondfloor 坑位约 35%屏(325pt)、且命中文字隔 2~3 层才到坑位 → 两关都挡掉，
//      于是「文字压0了、坑位容器仍占一大块高度」= 搜索栏下方纯白空白。
//      改：向上最多3层逐层判空壳，上限放宽 45%屏（仍低于50%黑屏硬闸门），必须真·空壳
//      （自身无文字+可见子view≤1且有尺寸）才压，遇根容器/大容器立即停。
//    ②88横幅：真机取证模板名只在 setTemplateItem:(DXTemplateItem:recommend_m_home_2025_88_
//      campaign_card_67) 出现，setData: 数据里 template=0键为空；v29~v32 只 hook setData，
//      所以日志显示「源头拦截命中」但横幅照常完整渲染。
//      改：FCHookSetTemplate 命中 tpl:/内置模板即不设模板并打实例标记，FCHookSetData 联动
//      return；模板名不命中时清标记自愈，防 DXRootView 复用导致正常卡片被误拦。
//    例行 __fcadVer 32→33。
//
//  v32 相对 v31（老大 v31 深扫定案 + 明确指令「把窗口大小改成0」）：
//    【定案】深扫输出「数据里未找到广告文案——文案写在远程模板zip」——证明 secondfloor
//    的消费券/领券中心文案写死在远程模板包，数据层无法按文案删，只能视图层处理。
//    【核心改造】隐藏手段从 removeFromSuperview 改为「压0塌陷」：命中元素不摘出视图树，
//    只把 frame.size 压成 0 + alpha=0 + clipsToBounds=YES。原因：remove 后节点离开视图树，
//    DX 动态化引擎下一帧重建该节点 → 扫描器够不着 → 「删→重绘」拉锯、留白复现；压0则节点
//    一直在树里，新增 FCReapplyAllZeroFrames() 每轮扫描开头重新压制，DX 重设 frame 也压得回。
//    FCFlattenRecord 增 originalFrame/alpha/clips/zeroCollapsed，规则删除时 FCRestoreZeroRecord 还原。
//    空壳父容器（留白框）同样改压0。诊断/浮标新增「压N个窗口」实时可见。
//    例行 __fcadVer 31→32。
//
//  v31 相对 v30（老大 v30 真机——源头拦截验证成功+发现点选误判 bug）：
//    【成功证据】内置命中5、日志出现两条 [源头拦截]（88_campaign/campaign_bottom_bar），
//    hook 数据入口链路通；超级88数据被拦后剩模板空壳（留白）。
//    【点选 bug】老大点「3张177元消费券」报「这是输入控件」——运营条按钮正是系统
//    UITextField/UITextView，v21 加的精确输入拦截挡住了广告点选。改为只拦键盘私有容器
//    (UIInputSet/UIKeyboard)，放行普通输入控件。
//    【深扫定案】添加 FCProbeDeepWalk 递归8层，对 secondfloor 数据把命中广告文案的
//    完整 key 路径打进诊断——判定文案在不在数据里：在→下版做 item 级精准删（不碰我的订单）；
//    不在→文案写在远程模板zip，只能视图层/源头模板拦。诊断新增「secondfloor 文案深扫」段。
//    例行 __fcadVer 30→31。
//
//  v30 相对 v29（老大 v29 诊断：Deep 档对了，但规则仍 10 条旧文字——没重新点选，
//  且发现两个真 bug 让点选即使做了也可能白费）：
//    ①模板提取漏分支：真机取证多数卡片模板名在 data.style.template（22键那批），
//      v29 只取顶层 template / data.template，补 style.template 两级；
//    ②点选取名不可靠：v29 靠 KVC 读 DXRootView.data 属性（Swift/ObjC 混合很可能读不到），
//      改为 hook 在 setTemplateItem:/setData: 时建立「实例→模板名」bridge 映射，
//      点选直接查表；
//    ③内置两个身份型广告模板 88_campaign(超级88) / campaign_bottom_bar(底部活动条)，
//      用核心身份子串匹配避开版本号，尊重内置开关——不点选也能先见效；
//    ④每版例行 __fcadVer 29→30。
//    说明：tpl: 规则仍需用户点选生成，内置只覆盖两个铁证模板。
//
//  v29 相对 v28（老大 Deep 档源头参数取证决定性证据）：
//    【证据】12 条 setData: 参数全是 NSDictionary，data.template.name/version 直接可读
//    （如 name=secondfloor/version=10 → DXTemplateItem:secondfloor_10）；
//    setTemplateItem: 对象 description 带完整模板名（recommend_m_home_2025_88_campaign_card_67
//    即老大一直要去的「超级88领券中心」）。用户文字规则 0 命中——文案不在这两层摘要深度内，
//    但模板名确定可见且比文案稳定（服务端改文案不改模板身份）。
//    【根治思路】不再视图层删了被 DX 重绘：源头 setData: 若模板名命中 tpl: 规则，
//    直接不调原 IMP——数据不进引擎，卡片无从渲染，自然不会重绘。
//    ①点选命中元素向上找 DXRootView，读 data.template 或 templateItem description，
//      自动存 tpl:模板名 规则（通用能力，不硬编码淘宝模板）；
//    ②Deep 档 FCHookSetData 精确匹配 tpl: 规则命中即返回，未命中才调原实现；
//    ③tpl: 纳入指纹类规则（精确去重/160字上限/面板「模」标签/诊断类型标注）；
//    ④浮标提示显示模板名，老大一次截图即可确认点中了哪个模板。
//    【安全】仅精确匹配，不用子串；只拦用户明确点选的模板；清空规则菜单可即时自救。
//
//  v28 相对 v27（老大回传 v27 真机 DX 类表/方法名——取证成功）：
//    【拿到的证据】DXRootView 确有 setData:/setTemplateItem: 数据入口；Swift 类
//    _TtC23TurboUIBuilderFramework11DXCardModel 真机存在但自身仅 init/.cxx_destruct，
//    业务方法不暴露 ObjC 运行时 → 印证 swizzle 够不着，静态判断被真机证实。
//    【仍缺一环】不知道 setData: 传进来的数据形态，无法判断广告文案在不在数据里；
//    猜着写过滤会清空整页数据（黑屏）。故 v28 只在 Deep 档加「源头参数取证」hook：
//    ①hook DXRootView setData:/setTemplateItem: 与 DXScrollerLayoutCell setViewModel:，
//      只旁听参数、先记后调原 IMP，不改返回值与调用顺序；
//    ②递归摘要(深度≤3/层6键3元素/单条单行≤700字)+去重40条上限，防日志爆炸；
//    ③扫描用户文字规则，命中即打【命中广告:xxx】——一眼判定源头可否精准过滤。
//    Pure 档保持零 hook 不变；诊断面板输出取证段，精简复制优先收录。
//
//  v27 相对 v26（老大真机诊断：命中:✓的「领券中心」「待使用」仍可见）：
//    【停止盲改，转源头取证】v24/v25/v26 连续三版在 Pure 视图层猜「删哪层容器」均无效，
//    诊断「命中✓仍可见」证明删掉的 DX 节点被引擎下一帧重绘恢复，视图层已到天花板。
//    静态分析确认 DXCardModel 是 Swift 类(_TtC23TurboUIBuilderFramework11DXCardModel)，
//    常规 ObjC method swizzle 够不着；ObjC 侧 DXBaseDataParser/DXRootView 虽存在，但没有
//    真机方法名就无法写精准 hook。故 v27 只加「只读运行时取证」，不动任何隐藏逻辑：
//    ①objc_copyClassList 扫全部类，列出真实 DX/TurboUI 类名（从真机反推前缀，不猜）；
//    ②对 DXRootView/DXBaseDataParser/DXImageView/DXTextView 等关键类，列自身+两层父类
//      的 selector 清单，定位 data/model/bind/render 入口，供 Deep 档源头拦截；
//    ③诊断面板输出 [DX类表]/[DX方法]，精简复制同步保留。纯只读，A/B 两档均不 hook。
//
//  v26 相对 v25（老大真机诊断决定性证据：命中:✓的元素仍可见、留白框还在）：
//    【纠正方向】v25「猜外层卡片整块删」是错的——诊断显示命中✓元素仍在树里可见，
//    真相是删了 DX 管理的容器后，阿里 DX 动态化引擎下一帧重绘恢复，进入「删→重绘」打架，
//    表现为留白/时有时无。改为：①FCCardShellForHide 回退为「只删命中元素自身」，不碰
//    DX 大容器，粒度精确不与引擎打架；②新增 FCRemoveEmptyShellIfNeeded——删掉命中元素后
//    若直接父容器被删空（无文字+子view≤1+尺寸像块）则连空壳一起移除，消除留白框。
//    【技术天花板】DX 是服务端驱动的原生动态化，视图层删除存在「删了又重绘」的拉锯，
//    Pure 档视图扫描有天然上限；彻底根治需 Deep 档从宿主广告数据/源头拦截（待评估）。
//
//  v25 相对 v24（老大真机：点选生效、内置命中2，但①隐藏后留空白方块②部分元素选不中）：
//    ①留白根因：命中文字 label（如「淘宝直播抢10亿」/「芭芭农场」）只删了 label，外层带
//      背景/固定高度的卡片容器还在占位置。新增 FCCardShellForHide：从命中 view 往上找
//      最内层「宽≥60/高36~30%屏/子view≤8/父更大」的卡片整块移除，下方元素自动补齐；
//      高度上限远小于 50%屏 防黑屏闸门。
//    ②「这是输入控件」误判：阿里 DX 的 DXTextView 内部继承 UITextField 被 isKindOfClass
//      误判。改为只有类名精确等于 UITextField/UITextView 或系统输入私有前缀才拦，宿主
//      自定义子类一律放行。
//    ③定位增强：点选红框标签带「引擎·类名/文字」，截图一次定位命中了什么，不再靠猜。
//
//  v24 相对 v23（老大真机：不再黑屏，但「界面元素都无法选取」，浮标「H5内元素·网页拾取
//  失败」/「这是输入控件」；诊断显示残留 pos:0,0,1,1 全屏垃圾规则）：
//    根因：①FCHitViewAtPoint 自写深度遍历把覆盖在最上的空壳 WKWebView 内部 WKScrollView 当
//    hit（DOM空），引擎判 H5→JS失败→降级又被 webInternal(祖先链有WK)拦死；真正运营位在
//    下面 DX 层够不着。②输入控件误判：rangeOfString:Keyboard/InputSet 太宽泛。③残留全屏
//    pos 规则:0,0,1,1。
//    修复：①点选命中落在 WK 内部时，穿透找同坐标下最深的 DX/RN/Flutter 宿主 view 替换 hit；
//    ②降级原生只看命中元素「自身引擎」是否 H5，不再看祖先链 WK；③输入拦截收紧为精确前缀；
//    ④pos/cls 规则拒绝占屏≥90% 的根容器，启动时自愈清除历史全屏规则。
//    网络取证真机已验证：捕获 91 条 URL（alicdn 图片/字体/JS），证明旁听通道有效。
//
//  v23 相对 v22（老大真机：打开软件直接黑屏，浮标「原17」=17 个元素被塌陷）：
//    【黑屏根因】v22 让「用户硬命中」绕过全部尺寸闸门，含 height>50%屏 的根容器保护；
//    点选存的 cls: 祖先链规则命中页面根容器(DXRootView 等) → 整块 removeFromSuperview → 黑屏。
//    修复①：大容器闸门(height>50%屏 或 width>95%屏)无条件生效，任何规则不得移除，防黑屏底线；
//    仅小元素(height<18/width<40)的用户硬命中仍放行，保留 17pt「领券中心」可隐藏。
//    修复②：浮标菜单 topVC 用 FCHostTopVC 兜底，黑屏/异常时仍能弹出「清空规则」自救。
//    ③【新增】进程内网络取证（替代电脑 Fiddler）：注册 FCNetProbe(NSURLProtocol) 只读旁听
//    App 请求 URL，canInitWithRequest 记下即 return NO——不接管/不改包/不 hook 系统方法，
//    默认关闭、菜单主动开启；诊断面板输出「----- 网络取证」段，精简版保留。天然不受 SSL
//    Pinning 影响（不解密只读 URL）。局限：宿主若有拦截型 protocol 先处理可能漏记。
//
//  v22 相对 v21（老大发来 v21 诊断文本——日志能发了，但暴露诊断口径误导 + 小元素隐藏失效）：
//    诊断证据：领券中心=[DX动态] DXImageView 130x17 (19,663)、顶层VC:-、所有元素「命中:无」
//    但有 1 条用户规则。三个根因一并修：
//    ①诊断口径误导：v21 只拿元素「自身文字」(FCOwnTextOf) 判命中，不查 cls:/pos: 指纹与
//      类名，隐藏已生效也会显示「命中:无」。新增 FCDiagHitRule 完整复刻 FCApplyNativeRules
//      的真实判定（类名精确→指纹→子树文字），命中行显示「✓规则」。
//    ②诊断不显示规则内容——无法判断点选存的到底是文字还是指纹。顶部逐条打印
//      「规则N[类名/位置/文字]: 内容」，精简版也保留。
//    ③真隐藏 bug：尺寸闸门 height<18 在命中判定之前，真机「领券中心」仅 17pt 被直接跳过，
//      存了规则也永远隐藏不了。改为先判用户规则硬命中、命中即绕过尺寸闸门；内置词仍走闸门。
//    ④修顶层VC:-（FCDiagWindow 抢 keyWindow）——新增 FCHostTopVC 遍历非插件 window。
//    ⑤诊断结束语文案「一键复制全部」→「复制精简」。
//
//  v21 相对 v20（老大反馈「日志文件字数太多我无法发送」+ 点搜索框误选键盘容器截图）：
//    ①诊断日志瘦身：新增 FCOwnTextOf 只取 view 自身文字，不再对每个 view 递归整棵子树
//      收集文字（旧版父容器与子 label 反复重复输出同样内容，日志暴涨到无法发送）；
//      诊断循环按 class+文字+坐标 去重，正文最多 80 行，超限提示改走复制精简。
//    ②复制双模式：诊断顶栏改为「关闭 / 复制精简 / 复制全文」三按钮；新增
//      FCDiagBriefString 从全文提炼要点（标题/顶层VC/用户规则/引擎图例/命中行），
//      最多 45 行，用户直接粘贴精简版发我，无需截图也无需发超长日志。
//    ③点选系统输入控件拦截：FCPickNative 开头跳过 UITextField/UITextView/UIInput*/
//      _UIInput*/Keyboard/InputSet 等键盘与输入容器，浮标提示「点广告内容区」，
//      杜绝点搜索框选中 UIInputSetContainerView 记 0 类。
//    ④注入脚本 __fcadVer 20→21，确保热更新后的新词表/幂等锁生效。
//
//  v20 相对 v19（老大三张真机截图 + 诊断输出定案）：
//    诊断证据：所有板块都是 [原生] DXRootView/DXScrollerLayoutCell/DOOTabItem/AUIconFontView，
//    顶层VC=TBMainViewController；唯一 WKWebView frame 0,0 430x932 却 DOM空=空壳容器。
//    → 之前判「运营位是 H5」错误！真相是阿里 DX 原生动态化，被空壳 webview 带偏。
//    修复三块：
//    ①新增元素引擎识别体系 FCEngine/FCEngineOfClass/FCEngineOfView——点选按命中元素
//      真实引擎(DX动态/RN/H5/原生/Flutter/小程序)路由：非 H5 直接走原生，不再看祖先链
//      有无 webview；浮标显示「DX动态·已记N类」让用户看清点中了哪类板块。
//    ②诊断面板：关闭/复制按钮移到 TextView 上方的固定顶栏（旧版 TextView 覆盖按钮点不到）；
//      新增「一键复制全部」+ toast，用户粘贴文本发我，无需截图；每行标注板块引擎。
//    ③诊断开头加引擎图例与「空壳 webview」提示，便于用户理解为何有的板块选不中。
//
//  v19 相对 v18（真机截图：浮标「网页未中→原生·已记0类+位置」，红框「已选中:WKScrollView」）：
//    证据链：v18 降级链路生效，但选中 WKScrollView=运营位其实是 H5 渲染在 WKWebView 内，
//    网页 JS 拾取失败、降级原生对 H5 无效（原生树无宿主类可记，0类）。
//    修复：①FCPickJSFmt 加固——命中 body/空白时在触点周围偏移再试；向上找容器时限制不越过
//      body、高度≤85%视口；容器过大退回用命中元素本身（避免隐藏整版）；补抓 innerText/alt/id/class/img。
//    ②JS 具体失败码透传浮标（网页空点/网页过大/网页报错），截图一次即可定位；
//    ③降级原生时若命中在 webview 内部(hit→祖先含 WK*)，只记诊断不隐藏、不存全屏 pos 规则，
//      提示「H5内元素·网页拾取失败,请点文字处重试」，杜绝隐藏整个网页。
//
//  v18 相对 v17（真机截图：淘宝「我的淘宝」页点选运营位，浮标显示「网页·未命中元素」）：
//    根因：FCPickAtPoint 只要触点祖先链有 WKWebView 就锁死走网页通道，elementFromPoint
//    返回 MISS/TOOBIG/err 就直接失败、不降级原生。而淘宝页面常驻各种 H5 容器 webview
//    （预热/广告SDK），会员中心/超级88领券中心/金刚区这些运营位是原生/Weex 渲染，
//    被 webview 带偏后 JS 抓不到 → 点选永远失败。
//    修复：①web 通道加前置校验（可见 + 宽高≥160 + frame 覆盖触点），排除 1x1 隐藏 webview；
//    ②网页 JS 失败(MISS/TOOBIG/err/无特征)自动降级到 FCPickNative 走原生拾取，浮标提示
//      「网页未中→原生·已记N类」让用户看降级发生；③原生拾取抽成函数两路复用，并排除
//      WKContentView/WebView 私有类，避免存下无效 cls: 规则。
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
#import <objc/message.h>   // v41：只写不读地调 setter，避免 KVC/读属性碰到野指针

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
static void FCPickNative(UIView *hit, CGPoint screenP, NSString *fallbackHint);  // v18：网页失败降级原生
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
static UIView *FCCardShellForHide(UIView *hit);   // v25：隐藏时找整块卡片外壳
static void FCRemoveEmptyShellIfNeeded(UIView *removedFrom, NSString *rule);  // v26：空壳父容器清理
static void FCZeroSourceRoot(UIView *root, NSString *tpl);   // v34：源头模板压0
static void FCZeroSourceRootIfBlocked(UIView *v);            // v34：扫描阶段判定+压0
static void FCPruneSourceZeros(void);   // v34：源头压0复用自愈
static void FCZeroBlockedCellShell(UIView *root);            // v37：源头拦截/压0 root → 塌陷外层空壳 cell
static void FCPruneBlockedCellShells(void);                  // v37：外壳 cell 压0复用自愈
static void FCZeroRotorCellIfEmpty(UIView *cell);            // v38：满宽矮轮播空壳 cell → 压0（不依赖源头痕迹）
static void FCPruneRotorCells(void);                         // v38：轮播空壳自愈——内部出现正常文字即还原
static void FCZeroDXHeightSpec(UIView *root);                 // v40：把被拦 root 的 DX 高度规格置0（真减高度）
static void FCEnqueueRelayout(UIView *v);                     // v41：重排只入队（弱引用），绝不在 cell 配置期同步重排
static void FCPerformPendingRelayout(void);                   // v41：扫描 tick 里统一执行入队的重排
static NSUInteger FCCellLiveTextCount(UIView *v, int depth);  // v45：前向声明（压0 目标升级到整行时要用）
static void FCMarkRowZero(UIView *cell);                      // v45：把所在表格行登记为高度 0（Deep 才有实现）
static void FCPruneRowMarks(void);                            // v45：每轮校验行号归属，防止压错正常行
static void FCUnmarkRowZero(UIView *cell);                     // v46：撤销行高归零登记（规则被删/记录还原时）

#pragma mark - H5 脚本模板

static NSString * const FCJSAdCardsTemplate =
@"(function(){var W=window;W.__fcadUserRules=%@;"
// v13：版本号——规则/词表热更新时必须重建 sweep（闭包里的 K 是旧词表，幂等 return 会让它永不更新）
"if(W.__fcadLoaded&&W.__fcadVer===47){if(W.__fcadSweep){W.__fcadSweep();}return;}"
"W.__fcadLoaded=1;W.__fcadVer=47;W.__fcadHits=0;"
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
@"(function(){var X=%f,Y=%f;var e=document.elementFromPoint(X,Y);"
"function vis(el){if(!el||el===document.body||el===document.documentElement)return false;"
"var r=el.getBoundingClientRect();return r.width>8&&r.height>8;}"
// v19：命中 body/空白时，在触点周围小范围偏移再试，抓真正的最上层元素
"if(!vis(e)){var O=[[6,0],[-6,0],[0,6],[0,-6],[16,10],[-16,10],[16,-10],[-16,-10],[0,20],[0,-20]];"
"for(var i=0;i<O.length;i++){var q=document.elementFromPoint(X+O[i][0],Y+O[i][1]);"
"if(vis(q)){e=q;break;}}}"
"if(!vis(e))return 'MISS';"
// v19：从命中元素向上找「可隐藏的卡片容器」——限制不越过 body，且高度不超 85% 视口
"var t=e;for(var k=0;k<3;k++){var p=t.parentElement;if(!p||p===document.body||p===document.documentElement)break;"
"var pr=p.getBoundingClientRect(),tr=t.getBoundingClientRect();"
"if(tr.height>0&&pr.height<=tr.height*1.8&&pr.width<=window.innerWidth*0.97&&pr.height<=window.innerHeight*0.85){t=p;}else{break;}}"
"var r=t.getBoundingClientRect();"
// v19：容器过大时不用整块，退回用命中元素本身（更精准，避免隐藏整个版块）
"if(r.height>window.innerHeight*0.85||r.width>window.innerWidth*0.99){t=e;r=t.getBoundingClientRect();"
"if(r.height>window.innerHeight*0.85)return 'TOOBIG';}"
"var out=[];function add(s){if(s&&(''+s).length>=1&&out.indexOf(''+s)<0)out.push(''+s);}"
"add((t.innerText||t.textContent||'').trim());"
"add((e.innerText||e.textContent||'').trim());"
"if(t.getAttribute){add(t.getAttribute('alt'));add(t.getAttribute('aria-label'));"
"if(t.id)add('#'+t.id);"
"var c=t.className&&(''+t.className).trim().split(/\\s+/)[0];if(c)add('.'+c);"
"var src=t.getAttribute('src')||t.getAttribute('data-src')||e.getAttribute('src');"
"if(src){var m=src.split('/').pop().split('?')[0];"
"if(m&&m.length>=4&&/\\.(png|jpg|jpeg|gif|webp)/i.test(m))add('img:'+m);}}"
// v13：CSS 结构指纹——图片型运营位靠路径记住
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
    // v24：全屏 pos 规则判危险——真机残留 pos:0,0,1,1 曾导致点中根容器→整页黑屏。
    // 覆盖 ≥90% 屏宽的 pos 规则毫无去广告价值（不可能有广告占满整屏），一律拒绝+自愈清除。
    if ([rule hasPrefix:@"pos:"]) {
        NSArray *p = [[rule substringFromIndex:4] componentsSeparatedByString:@","];
        if (p.count == 4 && [p[2] doubleValue] >= 0.90 && [p[3] doubleValue] >= 0.90) return YES;
        return NO;
    }
    if ([rule hasPrefix:@"#"] || [rule hasPrefix:@"."] || [rule hasPrefix:@"img:"] ||
        [rule hasPrefix:@"cls:"] || [rule hasPrefix:@"sel:"]) return NO;
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
                      [s hasPrefix:@"cls:"] || [s hasPrefix:@"img:"] ||
                      [s hasPrefix:@"tpl:"]) ? 160 : 40;   // v29：tpl: 模板名必须完整保留
    if (s.length > cap) s = [s substringToIndex:cap];
    return s;
}

// v43：规则质量门槛——拦掉「点选误触」产生的垃圾规则。
// 真机实证：v42 点选把 9 条规则存进了这批垃圾——
//   「猜你喜欢,已选中」（tab 标题 + 状态词被拼成一串，命中只会误伤容器）
//   「待使用」「返回顶部」（按钮状态词，隐藏了也没意义）
// 这类规则既拦不到广告，又可能命中含相同字串的正常容器，必须在入口拦住。
static BOOL FCRuleIsJunk(NSString *rule) {
    if (rule.length < 2) return YES;
    BOOL fingerprint = [rule hasPrefix:@"tpl:"] || [rule hasPrefix:@"cls:"] ||
                       [rule hasPrefix:@"pos:"] || [rule hasPrefix:@"sel:"] ||
                       [rule hasPrefix:@"img:"];
    if (fingerprint) return NO;                       // 指纹类规则不参与文字门槛
    // 复合串：点选时多个 label 的文本被拼在一起，一定不是单个广告标题
    NSCharacterSet *sep = [NSCharacterSet characterSetWithCharactersInString:@"，,、;；|｜/／"];
    if ([rule rangeOfCharacterFromSet:sep].location != NSNotFound) return YES;
    static NSArray<NSString *> *junkWords = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        junkWords = @[@"待使用", @"去使用", @"已选中", @"返回顶部", @"更多", @"全部",
                      @"设置", @"消息", @"客服", @"立即领取", @"查看更多", @"展开", @"收起"];
    });
    return [junkWords containsObject:rule];
}

static void FCAddUserRule(NSString *raw) {
    NSString *rule = FCJSSafe(raw);
    if (rule.length < 2) return;
    if (FCIsUnsafeClassRule(rule)) { FCLog(@"拒绝危险 class 规则：%@", rule); return; }   // v7
    // v43：入口拦垃圾规则（误点产生的复合串/状态词），避免越点越乱
    if (FCRuleIsJunk(rule)) { FCLog(@"拒绝垃圾规则（误点产物）：%@", rule); return; }
    NSMutableArray *a = [NSMutableArray arrayWithArray:FCUserRules()];
    BOOL isFingerprint = [rule hasPrefix:@"sel:"] || [rule hasPrefix:@"cls:"] ||
                         [rule hasPrefix:@"pos:"] || [rule hasPrefix:@"img:"] ||
                         [rule hasPrefix:@"tpl:"] ||                 // v29：模板指纹精确去重
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

#pragma mark - v20：元素板块引擎识别（原生 / DX-Weex / RN / H5 / Flutter / 小程序）

// iOS App 板块底层实现识别——按 view 类名特征判定渲染引擎。
// 依据：真机诊断「超级88领券中心」= DXRootView（阿里 DX 原生动态化），并非 H5；
// 页面里 frame 0,0 满屏但 DOM空 的 WKWebView 是空壳容器，不能据它判 H5。
typedef NS_ENUM(NSUInteger, FCEngine) {
    FCEngineUnknown = 0,
    FCEngineNative,    // 纯原生 UIKit（UILabel/UIImageView/自定义 UIView）
    FCEngineDX,        // 阿里 DX / Weex 原生动态化（DXRootView/DXScrollerLayoutCell...）
    FCEngineRN,        // React Native（RCTView/RCTText...）
    FCEngineH5,        // WKWebView 内的真 H5 DOM
    FCEngineFlutter,   // Flutter（FlutterView/FlutterViewController）
    FCEngineMiniApp,   // 小程序容器
};

static NSString *FCEngineName(FCEngine e) {
    switch (e) {
        case FCEngineNative:  return @"原生";
        case FCEngineDX:      return @"DX动态";
        case FCEngineRN:      return @"RN";
        case FCEngineH5:      return @"H5";
        case FCEngineFlutter: return @"Flutter";
        case FCEngineMiniApp: return @"小程序";
        default:              return @"未知";
    }
}

// 从类名判定引擎（用于沿祖先链找板块根容器）
static FCEngine FCEngineOfClass(NSString *cls) {
    if (!cls.length) return FCEngineUnknown;
    NSString *u = cls.uppercaseString;
    // 阿里 DX / Weex / Utah / Birdge：真机实证 DXRootView / DXScrollerLayoutCell / DOOTabItem
    if ([u hasPrefix:@"DX"] || [u hasPrefix:@"WX"] || [u rangeOfString:@"WEEX"].location != NSNotFound ||
        [u hasPrefix:@"Doo"] || [u hasPrefix:@"DOO"] || [u rangeOfString:@"DYNAMIC"].location != NSNotFound)
        return FCEngineDX;
    if ([u hasPrefix:@"RCT"] || [u rangeOfString:@"REACTNATIVE"].location != NSNotFound) return FCEngineRN;
    if ([u rangeOfString:@"FLUTTER"].location != NSNotFound || [u hasPrefix:@"FLT"]) return FCEngineFlutter;
    if ([u rangeOfString:@"MINIAPP"].location != NSNotFound || [u rangeOfString:@"MINIPROGRAM"].location != NSNotFound)
        return FCEngineMiniApp;
    if ([u hasPrefix:@"WK"] || [u rangeOfString:@"WEBVIEW"].location != NSNotFound) return FCEngineH5;
    if ([u hasPrefix:@"UI"] || [u hasPrefix:@"NS"] || [u isEqualToString:@"UIView"] ||
        [u hasPrefix:@"_UI"]) return FCEngineNative;
    // 其它宿主自定义类一律算原生（含 Swift 点号类名）
    return FCEngineNative;
}

// 从触点 view 沿祖先链找「板块引擎根」——返回最具体的引擎（DX/RN/H5 优先于原生）
static FCEngine FCEngineOfView(UIView *view) {
    FCEngine best = FCEngineUnknown;
    UIView *cur = view;
    for (int d = 0; cur && d < 10; d++) {
        FCEngine e = FCEngineOfClass(NSStringFromClass([cur class]));
        if (e == FCEngineDX || e == FCEngineRN || e == FCEngineH5 ||
            e == FCEngineFlutter || e == FCEngineMiniApp) { best = e; break; }
        if (e == FCEngineNative && best == FCEngineUnknown) best = FCEngineNative;
        cur = cur.superview;
    }
    return best == FCEngineUnknown ? FCEngineNative : best;
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

// v21：只取 view「自身」的文字（不递归子树）——诊断专用。
// FCTextsOf 对每个 view 都收集整棵子树，导致父容器/子label 反复输出同一段文字
// （老大反馈日志几千字发不出去）。诊断改用本函数，每个元素只报自己的文字。
static NSString *FCOwnTextOf(UIView *v) {
    if (!v || v.hidden || v.alpha < 0.05 || v.tag == 9527 || v.tag == 9528) return nil;
    NSString *s = nil;
    if ([v isKindOfClass:[UILabel class]]) {
        s = ((UILabel *)v).text;
        if (!s.length) s = ((UILabel *)v).attributedText.string;
    } else if ([v isKindOfClass:[UIButton class]]) {
        s = ((UIButton *)v).currentTitle;
        if (!s.length) s = ((UIButton *)v).titleLabel.attributedText.string;
    } else if ([v isKindOfClass:[UITextField class]]) {
        s = ((UITextField *)v).text;
    } else if ([v isKindOfClass:[UITextView class]]) {
        s = ((UITextView *)v).text;
    }
    if (!s.length) s = v.accessibilityLabel;
    return (s.length && s.length < 80) ? s : nil;
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

#pragma mark - v23：进程内网络取证（只读旁听，不改请求、不 hook 系统方法）

// 原理：注册一个 NSURLProtocol 子类，在 canInitWithRequest: 里「旁听」到 App 发出的请求 URL，
// 记下后立即 return NO——不接管、不修改请求、不建立连接，完全不改变网络行为。默认关闭，
// 只有用户在菜单主动开启才 registerClass。对比电脑 Fiddler：不需要代理/证书，天然不受
// SSL Pinning 影响（我们不解密、只读 URL 字符串）。局限：若宿主自己注册了拦截型 protocol
// 且先处理，我们的旁听可能收不到部分请求——这是可接受的诊断边界，不影响网络本身。
static NSMutableArray<NSString *> *gFCNetLog = nil;
static BOOL gFCNetLogOn = NO;

@interface FCNetProbe : NSURLProtocol
@end
@implementation FCNetProbe
+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if (gFCNetLogOn) {
        NSString *u = request.URL.absoluteString;
        if (u.length > 6 && u.length <= 300 &&
            ![u hasPrefix:@"data:"] && ![u hasPrefix:@"file:"] && ![u containsString:@"fcadblock"]) {
            if (!gFCNetLog) gFCNetLog = [NSMutableArray array];
            if (![gFCNetLog containsObject:u] && gFCNetLog.count < 200) [gFCNetLog addObject:u];
        }
    }
    return NO;   // 关键：只旁听，绝不接管
}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {}
- (void)stopLoading {}
@end

static void FCNetProbeToggle(void) {
    gFCNetLogOn = !gFCNetLogOn;
    if (gFCNetLogOn) {
        static dispatch_once_t once;
        dispatch_once(&once, ^{ [NSURLProtocol registerClass:[FCNetProbe class]]; });
        if (!gFCNetLog) gFCNetLog = [NSMutableArray array];
        [gFCNetLog removeAllObjects];
    }
}

static UIViewController *FCTopViewController(void) {
    UIWindow *key = [UIApplication sharedApplication].keyWindow;
    UIViewController *vc = key.rootViewController; int guard = 0;
    while (vc.presentedViewController && guard++ < 12) vc = vc.presentedViewController;
    return vc;
}

#pragma mark - 原生规则定时扫描（v5：双向匹配 + 强制重扫）

// v16：塌陷移除记录——把命中的运营位从视图树摘掉，让下方元素自动补齐；规则删除时可插回
// v32：新增「压0塌陷」模式——节点留在视图树里，只把 frame 压成 0 + alpha=0，
//      每轮扫描重新施加压制。DX 动态化引擎重设 frame 后下一轮立刻压回，不进入「删→重绘」拉锯。
@interface FCFlattenRecord : NSObject
@property (nonatomic, strong) UIView *view;
@property (nonatomic, weak) UIView *superview;
@property (nonatomic, assign) NSUInteger index;
@property (nonatomic, copy) NSString *rule;
@property (nonatomic, assign) CGRect originalFrame;     // v32：压0前的原始 frame
@property (nonatomic, assign) CGFloat originalAlpha;    // v32
@property (nonatomic, assign) BOOL originalClips;       // v32
@property (nonatomic, assign) BOOL zeroCollapsed;       // v32：YES=压0模式，NO=旧移除模式
@end
@implementation FCFlattenRecord
@end
static NSMutableArray<FCFlattenRecord *> *gFCFlattened = nil;
// v34：源头模板压0记录（second_pit 等），与用户点选记录分开存，复用自愈时互不干扰。
static NSMutableArray<FCFlattenRecord *> *gFCSourceZeroed = nil;
// v37：源头坑位外层空壳 cell 压0记录（AliIFDXCollectionViewCell）。
// 内容被源头拦/压0后，外层 cell 仍占满宽高度=白块；独立表、每轮重压、痕迹消失即还原。
static NSMutableArray<FCFlattenRecord *> *gFCShellZeroed = nil;
// v38：轮播空壳 cell 压0记录（搜索栏下 86pt 轮播位，内部只剩红点、无有效文字）。
// v37 只认源头痕迹够不着它（tpl:- 拦:否）；v38 改按几何+内容判据直接认领，独立表+专属自愈口径。
static NSMutableArray<FCFlattenRecord *> *gFRotorZeroed = nil;
static char kFCZeroRec;   // v32：view → FCFlattenRecord（压0标记，扫描时快速识别）
// v33：实例级标记——setTemplateItem 命中后，后续 setData 也不放行。
// v37：前移到全局区，扫描阶段据此判定「源头拦截过的 root」（原来定义在 hook 区，扫描够不着）。
static char kFCBlockedRoot;
// v40：高度规格已归零标记——每个 root 只做一次，避免每轮反复写属性触发重排抖动。
static char kFCHeightZeroed;
static NSUInteger gFCZeroApplied = 0;  // v32：累计压制次数（诊断可见）
// v40：高度归零结果计数（诊断可见：成功/非NSNumber跳过/无spec）
static NSUInteger gFCHeightZeroOK = 0;
static NSUInteger gFCHeightZeroSkip = 0;
// v41：setOriginalHeightSpec: 的 type encoding。闪退复盘的关键取证——
// 崩溃是 ARC 去 retain 传给 setter 的「第三个参数」时炸的（0x3fffffff 是寄存器残值，
// 不是对象），所以必须把真实签名打出来看它到底是不是对象参数。
static NSString *gFCHeightSetEnc = nil;
// v40：v39 几何空壳压0 的开关（停用：压子视图不减高度，且会误伤正常运营位；留代码便于回退）
static const BOOL gFCRotorEnabled = NO;
// v42：被挡计数去重——旧实现每次扫描遍历都把「命中却被闸门挡下」的同一节点再 +1，
// 于是浮标上的「挡」每 tick 往上涨（真机 978 看着像挡了上千个广告，实际只有几个）。
// 用弱表记录已计过的节点：同一节点只计一次，数字从此稳定；节点释放自动出表。
static NSHashTable *gFCBlockedSeen = nil;
static NSUInteger gFCBlockedUnique = 0;   // 去重后的被挡节点数（浮标/诊断显示这个）
// v42：被源头拦截过的 DXRootView 弱表——实例级标记 kFCBlockedRoot 是关联对象，遍历不到；
// 「暂停拦截」时必须能逐个清标记，否则这些 root 会带着旧标记被 setData hook 继续 return。
static NSHashTable *gFCBlockedRoots = nil;
// v42：全局暂停开关——老大随时能「一键恢复原样」再点选广告。
// 暂停期间：不压0、不拦模板、不隐藏；已拦的还原并清标记。刷新页面后广告原样出现。
static BOOL gFCPaused = NO;
// v43：大块免压——高度超过阈值（120pt）的运营位不压0。
// 存在意义：压0 只让内容消失、不减坑位高度，压一块 155pt 的运营位就等于留 155pt 白。
// 小广告（商品流推广卡 60~100pt）压了几乎不留白，大块（四宫格/活动卡）压了就一大片空。
// 默认关（保持原有行为），用户在菜单里按需打开。
static NSString * const FCBigBlockKey = @"FCAdBlockBigBlockPass_v1";   // 用户开关，持久化
static const CGFloat kFCBigBlockH = 120.0;

static BOOL FCBigBlockPassOn(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:FCBigBlockKey];
}

// v45：向上找「所在表格行」——我的淘宝/丰巢这类列表页，每个板块 = 一个 UITableViewCell
// （真机坐标反查：目标外层是 UITableViewCellContentView → MTDinamicXCell，430x142）。
// 命中文字的往往比 cell 深 2~4 层，只压文字 → 文字没了、142pt 行高还在 = 一片白。
static UITableViewCell *FCEnclosingRowCell(UIView *v) {
    UIView *cur = v;
    int guard = 0;
    while (cur && guard++ < 7) {
        if ([cur isKindOfClass:[UITableViewCell class]]) return (UITableViewCell *)cur;
        cur = cur.superview;
    }
    return nil;
}

// v45：这个 view 压0 之后，能不能把「占的位置」也一起还回来？
// 表格行可以（把行高改成 0），其它容器不行（只能留白）。这个判断决定「大块免压」要不要跳过它：
// 免压的本意是「别制造大留白」，而能归零的行压了不会留白，就不该被跳过。
static BOOL FCRowZeroCapable(UIView *v) {
#ifdef FC_DEEP_HOOKS
    if (!v) return NO;
    UITableViewCell *rc = [v isKindOfClass:[UITableViewCell class]]
        ? (UITableViewCell *)v : FCEnclosingRowCell(v);
    if (!rc) return NO;
    UITableView *tv = nil;
    UIView *p = rc.superview;
    int g = 0;
    while (p && g++ < 8) {
        if ([p isKindOfClass:[UITableView class]]) { tv = (UITableView *)p; break; }
        p = p.superview;
    }
    if (!tv) return NO;
    // v45：只要它是表格行就算「可压」——不再要求 delegate 一定实现 heightForRow。
    // 理由：真机优先级是「先让它消失」。若 delegate 没实现（表格用 automaticDimension），
    // 行高归零做不了、会留白，但那是「去掉了留白」而不是「压根去不掉」；诊断
    // `[行高归零]` 会如实报「未接管代理」，下一版再针对性处理。
    return YES;
#else
    (void)v;
    return NO;
#endif
}

// v43：判断某个屏幕矩形是否该被「大块免压」跳过
// v45：多一个 target 参数——能归零的表格行不跳过（见 FCRowZeroCapable）。
static BOOL FCShouldSkipBigBlockFor(CGRect screenRect, UIView *target) {
    if (!FCBigBlockPassOn()) return NO;
    if (screenRect.size.height <= kFCBigBlockH) return NO;
    if (FCRowZeroCapable(target)) return NO;
    return YES;
}
static BOOL FCShouldSkipBigBlock(CGRect screenRect) {
    return FCShouldSkipBigBlockFor(screenRect, nil);
}
// v42：点选当场 hidden=YES 的卡片。点选时扫描是冻结的，这些 view 进不了 gFCFlattened，
// 规则清掉后没人会把它恢复 → 退出点选统一 hidden=NO，交给扫描按规则重新接管。
static NSHashTable *gFCPickHidden = nil;
// v42：点选冻结——进点选先把自己所有的拦截临时还原，页面回到原始状态。
// 不冻结的话「想选的广告早被自己压成0了」，那一片是空白，怎么点都只能点到外层容器。
static BOOL gFCPickFreeze = NO;

#pragma mark - v40/v41：DX 高度规格归零（唯一能真正减高度的入口）
// 注意：这几个函数必须放在 #ifdef FC_DEEP_HOOKS 之外——扫描阶段在 A/Pure 档也会调用，
// 定义若留在 Deep 段内，A 档会报 "function has internal linkage but is not defined"(DL4 坑)。

// v41：重排从「同步执行」改成「弱引用入队 + 扫描 tick 统一执行」。
// v40 真机崩溃根因（.ips 铁证：objc_retain + 8 崩在 0x3fffffff，栈为
// cellForItemAtIndexPath → initializeRootView → 本插件）：
// 在 diffable update 的 cell 配置链上同步调 invalidateLayout，UIKit 正在做 insert
// 动画/预取 cell，重入布局把「正在初始化的 root」提前释放；随后 initializeRootView
// 继续用野指针调 setOriginalHeightSpec:，hook 第一行读关联对象就 retain 到垃圾指针。
// 现在 hook 里只入队，真正 invalidateLayout 挪到 0.12s 扫描 tick（runloop 边界、
// 不在任何 UIKit update 事务里）。弱引用表还自带「view 已释放即消失」的兜底。
static NSHashTable *gFCRelayoutViews = nil;   // 弱引用：view 被释放自动从表里消失，不会野指针

static void FCEnqueueRelayout(UIView *v) {
    if (!v || !v.superview) return;           // 已离树的没必要重排
    if (!gFCRelayoutViews) gFCRelayoutViews = [NSHashTable weakObjectsHashTable];
    if (gFCRelayoutViews.count > 32) [gFCRelayoutViews removeAllObjects];  // 上限，防长会话堆积
    [gFCRelayoutViews addObject:v];
}

// v41：真正的重排。只在扫描 tick 里调用——主线程、runloop 边界、绝不在 cell 配置期。
static void FCPerformPendingRelayout(void) {
    if (!gFCRelayoutViews.count) return;
    NSArray *snap = gFCRelayoutViews.allObjects;   // 已释放的 view 不会出现在这里
    [gFCRelayoutViews removeAllObjects];
    for (UIView *v in snap) {
        UIView *p = v.superview;
        int guard = 0;
        while (p && guard++ < 10) {
            if ([p isKindOfClass:[UICollectionView class]]) {
                @try {
                    UICollectionView *cv = (UICollectionView *)p;
                    if (cv.collectionViewLayout) [cv.collectionViewLayout invalidateLayout];
                    [cv setNeedsLayout];
                } @catch (NSException *e) { }
                break;
            }
            if ([p isKindOfClass:[UITableView class]]) {
                @try {
                    UITableView *tv = (UITableView *)p;
                    [tv beginUpdates];
                    [tv endUpdates];
                } @catch (NSException *e) { }
                break;
            }
            p = p.superview;
        }
    }
}

#pragma mark - v45：表格行高归零（Deep）——压0 只能藏内容，行高还在就是白块，这一层才真把位置还回来

// 真机证据（v44 诊断）：我的淘宝页「超级88领券中心」= MTDinamicXCell 0,501 430x142，
// 外层是 UITableViewCellContentView → 它是 UITableView 的一行。压0 只把内容藏了，
// 行高 142pt 由 tableView 的行高决定，所以「去掉了还是一片白」。
// 唯一合法的改法：让这个表的 delegate 对「被我们点名的行」返回高度 0。
// 约束：只碰 App 自己的 delegate 类（系统类一律跳过），且必须先验方法签名再替换实现
// （DM2 教训：setter/hook 拿错签名去调，ARC 会去 retain 寄存器残值 → 100% 崩）。
// 整段包在 FC_DEEP_HOOKS 里：Pure 档要保证 nm -u 看不到 method_setImplementation。
#ifdef FC_DEEP_HOOKS
static NSMapTable *gFCRowMarks = nil;               // UITableView(弱) → NSMutableSet<"sec,row">
static NSHashTable *gFCRowZeroCells = nil;          // 被点名归零的 cell（弱引用，释放自动消失）
static NSMutableDictionary *gFCRowOrigIMPs = nil;   // Method 指针 → NSValue(原 IMP)
static NSMutableSet *gFCRowHookedKeys = nil;        // 已接管的 "cls|sel"（只用于诊断计数）
static NSString *gFCRowProbe = nil;                 // v46：最近一次登记时的代理探针（诊断可见）

static CGFloat FCRowHeightTrampoline(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip);

static BOOL FCRowIsMarked(UITableView *tv, NSIndexPath *ip) {
    if (!tv || !ip || !gFCRowMarks) return NO;
    NSMutableSet *s = [gFCRowMarks objectForKey:tv];
    if (!s.count) return NO;
    return [s containsObject:[NSString stringWithFormat:@"%ld,%ld",
                              (long)ip.section, (long)ip.row]];
}

// 【关键】原 IMP 必须按 **Method 指针**存，不能按类名存。
// 若 heightForRow 定义在 delegate 的父类里，method_setImplementation 改的是父类那份实现；
// 此时若按「子类名」存原 IMP，父类的其它实例进 trampoline 就查不到 → 回退成默认值 → 别的表全乱。
// 按 Method 指针存：任何实例都能用它自己类链上解析出的同一个 Method 指针查到原实现。
static IMP FCOrigRowIMPFor(id self, SEL sel) {
    if (!gFCRowOrigIMPs) return NULL;
    Method m = class_getInstanceMethod(object_getClass(self), sel);
    if (!m) return NULL;
    NSValue *v = [gFCRowOrigIMPs objectForKey:[NSValue valueWithPointer:(void *)m]];
    return v ? (IMP)v.pointerValue : NULL;
}

// 替换实现：只有「这个表 + 这个 indexPath」被点名过才返回 0，其它一律交还原实现。
// 这样即使多个页面共用同一个 delegate 类也不会被误伤。
static CGFloat FCRowHeightTrampoline(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (FCRowIsMarked(tv, ip)) return 0.0;
    IMP orig = FCOrigRowIMPFor(self, _cmd);
    if (!orig) return UITableViewAutomaticDimension;
    return ((CGFloat (*)(id, SEL, UITableView *, NSIndexPath *))orig)(self, _cmd, tv, ip);
}

// v46：找到「真正定义了这个方法」的类——用于判断能不能碰。
// 系统类（UIKit）里的实现绝对不能改：那会影响全 App 所有表格。
static Class FCDefiningClassOf(Class cls, SEL sel) {
    Class c = cls;
    int guard = 0;
    while (c && guard++ < 16) {
        unsigned int n = 0;
        Method *list = class_copyMethodList(c, &n);
        BOOL found = NO;
        if (list) {
            for (unsigned int i = 0; i < n; i++)
                if (method_getName(list[i]) == sel) { found = YES; break; }
            free(list);
        }
        if (found) return c;
        c = class_getSuperclass(c);
    }
    return Nil;
}

static BOOL FCIsSystemClassName(NSString *n) {
    return [n hasPrefix:@"UI"] || [n hasPrefix:@"NS"] || [n hasPrefix:@"_UI"] ||
           [n hasPrefix:@"WK"] || [n hasPrefix:@"CA"] || [n hasPrefix:@"__"];
}

// v46：自动行高表格的兜底——self-sizing 的行高由 cell 的
// systemLayoutSizeFittingSize:withHorizontalFittingPriority:verticalFittingPriority: 算出来。
// 被我们点名的 cell 直接返回高度 0，行就塌了（不依赖 delegate 实现 heightForRow）。
static CGSize FCRowSizeTrampoline(id self, SEL _cmd, CGSize size, float hp, float vp) {
    if (gFCRowZeroCells && [gFCRowZeroCells containsObject:self]) {
        return CGSizeMake(size.width, 0);   // 被点名的行：高度算成 0，行自然塌掉
    }
    IMP orig = FCOrigRowIMPFor(self, _cmd);
    if (!orig) {
        // v47：本方法是用 class_addMethod 加在 App 类上的，没有「原 IMP」可查——
        // 直接用父类（系统 UITableViewCell）的实现，注意只是**调用**它，没有改它。
        Class sup = class_getSuperclass(object_getClass(self));
        if (sup) orig = class_getMethodImplementation(sup, _cmd);
    }
    if (!orig) return size;
    return ((CGSize (*)(id, SEL, CGSize, float, float))orig)(self, _cmd, size, hp, vp);
}

// v47：真机 v46 的取证——代理 MTTableViewHolder 没有 heightForRow、rowH=-1(automatic)，
// 而 MTDinamicXCell 自己**没有**重写 systemLayoutSizeFittingSize（定义在 UITableViewCell）。
// 于是「改 delegate 行高」和「改已有实现」两条路都走不通，行高永远塌不了，压完就留一块白。
static void FCHookRowSizeSel(Class cls, SEL sel);   // v47：前向声明（下面是新增方法，定义在它之后）

// 解法：给 App 自己的 cell 类**新增**一个同名方法（class_addMethod），此时父类（系统）
// 的实现一个字都没动，只是子类有了自己的版本：被点名的实例返回 0 高，其它实例原样转给父类。
static void FCEnsureCellSizeHook(Class cellCls) {
    if (!cellCls) return;
    if (FCIsSystemClassName(NSStringFromClass(cellCls))) return;
    SEL sel = @selector(systemLayoutSizeFittingSize:withHorizontalFittingPriority:verticalFittingPriority:);
    if (!gFCRowHookedKeys) gFCRowHookedKeys = [NSMutableSet set];
    NSString *key = [NSString stringWithFormat:@"%s|%s",
                     class_getName(cellCls), sel_getName(sel)];
    if ([gFCRowHookedKeys containsObject:key]) return;
    // ① 该类自己已有实现（App 自定义）→ 直接换实现（原来的 IMP 会被存下来）
    Class defCls = FCDefiningClassOf(cellCls, sel);
    if (defCls == cellCls) {
        FCHookRowSizeSel(cellCls, sel);
        return;
    }
    // ② 只有父类（系统）有 → 给子类新增一份，不动系统实现
    Method base = class_getInstanceMethod([UITableViewCell class], sel);
    if (!base) return;
    const char *types = method_getTypeEncoding(base);
    if (!types) return;
    if (class_addMethod(cellCls, sel, (IMP)FCRowSizeTrampoline, types)) {
        [gFCRowHookedKeys addObject:key];
        FCLog(@"行高归零：已给 %@ 新增尺寸方法（父类实现未改动）", NSStringFromClass(cellCls));
    }
}

static void FCHookRowSizeSel(Class cls, SEL sel) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    if (!gFCRowOrigIMPs) gFCRowOrigIMPs = [NSMutableDictionary dictionary];
    NSValue *mkey = [NSValue valueWithPointer:(void *)m];
    if ([gFCRowOrigIMPs objectForKey:mkey]) return;
    const char *enc = method_getTypeEncoding(m);
    if (!enc) return;
    @try {
        NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:enc];
        if (!sig || sig.numberOfArguments != 5) return;
        if ([sig methodReturnType][0] != '{') return;           // 返回结构体(CGSize)
        if ([sig getArgumentTypeAtIndex:2][0] != '{') return;   // CGSize
    } @catch (NSException *e) { return; }
    IMP orig = method_getImplementation(m);
    [gFCRowOrigIMPs setObject:[NSValue valueWithPointer:orig] forKey:mkey];
    method_setImplementation(m, (IMP)FCRowSizeTrampoline);
    if (!gFCRowHookedKeys) gFCRowHookedKeys = [NSMutableSet set];
    [gFCRowHookedKeys addObject:[NSString stringWithFormat:@"%s|%s",
                                 class_getName(cls), sel_getName(sel)]];
    FCLog(@"行高归零：已接管 %@ 的 %@", NSStringFromClass(cls), NSStringFromSelector(sel));
}

static void FCHookRowHeightSel(Class cls, SEL sel) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    if (!gFCRowOrigIMPs) gFCRowOrigIMPs = [NSMutableDictionary dictionary];
    NSValue *mkey = [NSValue valueWithPointer:(void *)m];
    if ([gFCRowOrigIMPs objectForKey:mkey]) return;   // 这份实现已经接管过（含“父类已接管”）
    const char *enc = method_getTypeEncoding(m);
    if (!enc) return;
    @try {
        NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:enc];
        if (!sig || sig.numberOfArguments != 4) return;
        char ret = [sig methodReturnType][0];
        if (ret != 'd' && ret != 'f') return;                       // 必须返回 CGFloat
        if ([sig getArgumentTypeAtIndex:2][0] != '@') return;        // UITableView *
        if ([sig getArgumentTypeAtIndex:3][0] != '@') return;        // NSIndexPath *
    } @catch (NSException *e) { return; }
    IMP orig = method_getImplementation(m);
    [gFCRowOrigIMPs setObject:[NSValue valueWithPointer:orig] forKey:mkey];
    method_setImplementation(m, (IMP)FCRowHeightTrampoline);
    if (!gFCRowHookedKeys) gFCRowHookedKeys = [NSMutableSet set];
    [gFCRowHookedKeys addObject:[NSString stringWithFormat:@"%s|%s",
                                 class_getName(cls), sel_getName(sel)]];
    FCLog(@"行高归零：已接管 %@ 的 %@", NSStringFromClass(cls), NSStringFromSelector(sel));
}

// 把一个 cell 的所在行登记为「高度 0」，并装上代理钩子 + 触发一次重排。
static void FCMarkRowZero(UIView *cell) {
    if (!cell) return;
    UITableViewCell *rc = [cell isKindOfClass:[UITableViewCell class]]
        ? (UITableViewCell *)cell : FCEnclosingRowCell(cell);
    if (!rc) return;
    UITableView *tv = nil;
    UIView *p = rc.superview;
    int g = 0;
    while (p && g++ < 8) {
        if ([p isKindOfClass:[UITableView class]]) { tv = (UITableView *)p; break; }
        p = p.superview;
    }
    if (!tv) return;
    NSIndexPath *ip = [tv indexPathForCell:rc];
    if (!ip) return;   // 还不在可见区，别登记（indexPath 会错位）
    if (!gFCRowMarks) gFCRowMarks = [NSMapTable weakToStrongObjectsMapTable];
    if (!gFCRowZeroCells) gFCRowZeroCells = [NSHashTable weakObjectsHashTable];
    NSMutableSet *s = [gFCRowMarks objectForKey:tv];
    if (!s) { s = [NSMutableSet set]; [gFCRowMarks setObject:s forKey:tv]; }
    [s addObject:[NSString stringWithFormat:@"%ld,%ld", (long)ip.section, (long)ip.row]];
    [gFCRowZeroCells addObject:rc];
    id d = tv.delegate;
    NSString *dn = d ? NSStringFromClass(object_getClass(d)) : @"nil";
    SEL hSel = @selector(tableView:heightForRowAtIndexPath:);
    SEL eSel = @selector(tableView:estimatedHeightForRowAtIndexPath:);
    BOOL hasH = d && [d respondsToSelector:hSel];
    BOOL hasE = d && [d respondsToSelector:eSel];
    if (d) {
        Class dc = object_getClass(d);
        if (FCIsSystemClassName(dn)) {
            FCLog(@"行高归零：表格代理是系统类 %@，跳过", dn);
        } else {
            if (hasH) FCHookRowHeightSel(dc, hSel);
            if (hasE) FCHookRowHeightSel(dc, eSel);
        }
    }
    // v46 兜底：代理没实现 heightForRow（表格是 self-sizing）时，改 cell 自己的
    // systemLayoutSizeFittingSize: 让这一行算出 0 高。只碰「App 自己定义」的实现，系统类不碰。
    Class cellCls = object_getClass(rc);
    SEL sSel = @selector(systemLayoutSizeFittingSize:withHorizontalFittingPriority:verticalFittingPriority:);
    Class defCls = FCDefiningClassOf(cellCls, sSel);
    FCEnsureCellSizeHook(cellCls);
    BOOL sizeHooked = [gFCRowHookedKeys containsObject:
        [NSString stringWithFormat:@"%s|%s", class_getName(cellCls), sel_getName(sSel)]];
    gFCRowProbe = [NSString stringWithFormat:
        @"代理=%@ h=%@ e=%@ rowH=%.0f | cell=%@ 尺寸钩子=%@%@",
        dn, hasH ? @"有" : @"无", hasE ? @"有" : @"无", tv.rowHeight,
        NSStringFromClass(cellCls), sizeHooked ? @"装" : @"无",
        defCls ? [NSString stringWithFormat:@"(定义=%@)", NSStringFromClass(defCls)] : @"(未定义)"];
    FCLog(@"行高归零登记 %ld,%ld %@", (long)ip.section, (long)ip.row, gFCRowProbe);
    FCEnqueueRelayout(rc);
}

// v46：撤销一行的归零登记（规则被删 / 记录还原时调用），并让表格重算行高。
static void FCUnmarkRowZero(UIView *cell) {
    if (!cell || !gFCRowMarks || !gFCRowMarks.count) return;
    UITableViewCell *rc = [cell isKindOfClass:[UITableViewCell class]]
        ? (UITableViewCell *)cell : FCEnclosingRowCell(cell);
    if (!rc) return;
    UITableView *tv = nil;
    UIView *p = rc.superview;
    int g = 0;
    while (p && g++ < 8) {
        if ([p isKindOfClass:[UITableView class]]) { tv = (UITableView *)p; break; }
        p = p.superview;
    }
    if (!tv) return;
    NSMutableSet *s = [gFCRowMarks objectForKey:tv];
    if (!s) return;
    NSIndexPath *ip = [tv indexPathForCell:rc];
    if (ip) [s removeObject:[NSString stringWithFormat:@"%ld,%ld", (long)ip.section, (long)ip.row]];
    [gFCRowZeroCells removeObject:rc];
    if (!s.count) [gFCRowMarks removeObjectForKey:tv];
    FCEnqueueRelayout(rc);
}

// 每轮校验：行号对应的 cell 换人了（数据刷新/复用）就撤销登记，防止把正常行压成 0。
static void FCPruneRowMarks(void) {
    if (!gFCRowMarks || !gFCRowMarks.count) return;
    NSMutableArray *deadTables = [NSMutableArray array];
    for (UITableView *tv in gFCRowMarks.keyEnumerator) {
        if (!tv || !tv.superview) { [deadTables addObject:tv]; continue; }
        NSMutableSet *s = [gFCRowMarks objectForKey:tv];
        NSMutableSet *gone = [NSMutableSet set];
        for (NSString *k in [s copy]) {
            NSArray *p = [k componentsSeparatedByString:@","];
            if (p.count != 2) { [gone addObject:k]; continue; }
            NSIndexPath *ip = [NSIndexPath indexPathForRow:[p[1] integerValue]
                                                 inSection:[p[0] integerValue]];
            UITableViewCell *c = nil;
            @try { c = [tv cellForRowAtIndexPath:ip]; } @catch (NSException *e) { c = nil; }
            if (!c) continue;                                   // 不在可见区，先留着
            if (![gFCRowZeroCells containsObject:c]) [gone addObject:k];   // 换人了 → 撤销
        }
        if (gone.count) [s minusSet:gone];
        if (!s.count) [deadTables addObject:tv];
    }
    for (UITableView *tv in deadTables) [gFCRowMarks removeObjectForKey:tv];
}
#else
// Pure 档：零 hook，没有行高归零能力（FCRowZeroCapable 恒 NO），清理也就是空操作。
// v45：FCMarkRowZero 也必须有定义——只在前向声明区出现、定义落在 #ifdef 内，
// 是 v40 编译失败（-Wundefined-internal）的老坑（DL4），Pure 档必须有桩。
static void FCPruneRowMarks(void) { }
static void FCMarkRowZero(UIView *cell) { (void)cell; }
static void FCUnmarkRowZero(UIView *cell) { (void)cell; }
#endif

// v40：把被拦 DXRootView 的高度规格（originalHeightSpec）置 0。
// v41：**只写不读**。v40 用 valueForKey: 读回旧值 → 在半初始化/已释放的 DX 对象上
// 会把垃圾指针当对象 retain（正是这次闪退的崩溃点）。写 0 不需要读旧值，直接调 setter。
// 另外只碰「自己实现了该 setter」的对象；没有就跳过计数，绝不 KVC 兜底。
static void FCZeroDXHeightSpec(UIView *root) {
    if (!root) return;
    if (objc_getAssociatedObject(root, &kFCHeightZeroed)) return;   // 每个 root 只做一次
    SEL setter = @selector(setOriginalHeightSpec:);
    if (![root respondsToSelector:setter]) { gFCHeightZeroSkip++; return; }
    // v41：签名校验——参数必须是对象(@)，否则别拿 id 去调（结构体传值会毁栈）。
    NSMethodSignature *sig = [root methodSignatureForSelector:setter];
    if (!sig || sig.numberOfArguments < 3 || [sig getArgumentTypeAtIndex:2][0] != '@') {
        gFCHeightZeroSkip++;
        return;
    }
    objc_setAssociatedObject(root, &kFCHeightZeroed, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(root, setter, @0);
        gFCHeightZeroOK++;
    } @catch (NSException *e) {
        gFCHeightZeroSkip++;
        FCLog(@"v41 高度规格置0失败: %@", e.reason);
        return;
    }
    FCEnqueueRelayout(root);
}

// v32：规则是否仍匹配这条记录（与 FCRestoreFlattenedIfNeeded 同口径）
static BOOL FCRecordRuleStillValid(FCFlattenRecord *rec, NSArray<NSString *> *rules) {
    for (NSString *r in rules) {
        if ([r isEqualToString:rec.rule] ||
            [r rangeOfString:rec.rule].location != NSNotFound ||
            [rec.rule rangeOfString:r].location != NSNotFound) return YES;
    }
    return NO;
}

// v32：强制把 view 压成 0 尺寸——frame.size=0 + alpha=0 + clipsToBounds=YES（防子视图溢出）。
// 只在 DX/布局引擎把 frame 改回非0时才重设，避免每轮无谓赋值触发 DX 内部 KVO。
static void FCForceZeroFrame(UIView *v) {
    if (!v) return;
    CGRect f = v.frame;
    if (f.size.width > 0.5 || f.size.height > 0.5)
        v.frame = CGRectMake(f.origin.x, f.origin.y, 0, 0);
    if (!v.clipsToBounds) v.clipsToBounds = YES;
    if (v.alpha > 0.01) v.alpha = 0;
}

// v32：还原一条压0记录到原始尺寸
static void FCRestoreZeroRecord(FCFlattenRecord *rec) {
    UIView *v = rec.view;
    if (!v) return;
    // v46：还原的同时撤销「行高归零」登记——否则规则删了、内容回来了，那一行还是 0 高度。
    FCUnmarkRowZero(v);
    v.frame = rec.originalFrame;
    v.alpha = rec.originalAlpha;
    v.clipsToBounds = rec.originalClips;
    objc_setAssociatedObject(v, &kFCZeroRec, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// v42：点选专用——把所有拦截临时全部还原，页面回到「没装插件」的原始样子。
// 四张表一起清：用户规则塌陷(gFCFlattened) / 源头模板压0(gFCSourceZeroed) /
// 源头坑位外壳(gFCShellZeroed) / 几何空壳(gFRotorZeroed)。
// 存在意义（老大反馈「无法选择广告元素」的直接修法）：元素已经被自己挡掉了，
// 视觉上是空白、hitTest 也够不着，点选必然只能点到外层容器 → 永远选不中。
static void FCRestoreAllBlockedForPicking(void) {
    NSMutableArray *tables = [NSMutableArray array];
    if (gFCFlattened) [tables addObject:gFCFlattened];
    if (gFCSourceZeroed) [tables addObject:gFCSourceZeroed];
    if (gFCShellZeroed) [tables addObject:gFCShellZeroed];
    if (gFRotorZeroed) [tables addObject:gFRotorZeroed];
    NSUInteger n = 0;
    for (NSMutableArray *tb in tables) {
        for (FCFlattenRecord *rec in [tb copy]) {
            @try {
                FCRestoreZeroRecord(rec);
                if (rec.view) rec.view.hidden = NO;   // 旧移除模式可能留了 hidden
                n++;
            } @catch (NSException *e) { }
        }
        [tb removeAllObjects];
    }
    if (gFCBlockedSeen) [gFCBlockedSeen removeAllObjects];
    gFCBlockedUnique = 0;
    // v42：同时清实例级「源头拦截」标记，否则还原了 frame 也还是空的：
    // setData/setTemplateItem hook 看到 kFCBlockedRoot 就直接 return，数据永远不灌进去。
    NSUInteger cleared = 0;
    if (gFCBlockedRoots) {
        for (UIView *r in [gFCBlockedRoots allObjects]) {
            @try {
                objc_setAssociatedObject(r, &kFCBlockedRoot, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(r, &kFCHeightZeroed, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                cleared++;
            } @catch (NSException *e) { }
        }
        [gFCBlockedRoots removeAllObjects];
    }
    FCLog(@"还原全部拦截：%lu 处视图 + %lu 个源头标记（gFCPaused=%d）",
          (unsigned long)n, (unsigned long)cleared, (int)gFCPaused);
}

// v43：估算「被压掉的坑位高度合计」= 当前页面上留下了多少空白。
// 用途：老大一眼看到代价。压一个 155pt 的运营位就是 155pt 白，规则越多白越大。
// 去重口径：只累加「祖先没有压0记录」的节点，否则「源头容器 + 外层外壳」会算两遍。
static BOOL FCViewHasZeroedAncestor(UIView *v) {
    UIView *p = v.superview;
    int guard = 0;
    while (p && guard++ < 10) {
        if (objc_getAssociatedObject(p, &kFCZeroRec)) return YES;
        p = p.superview;
    }
    return NO;
}

static CGFloat FCWhiteSpaceEstimate(void) {
    CGFloat h = 0;
    NSMutableArray *tables = [NSMutableArray array];
    if (gFCFlattened) [tables addObject:gFCFlattened];
    if (gFCSourceZeroed) [tables addObject:gFCSourceZeroed];
    if (gFCShellZeroed) [tables addObject:gFCShellZeroed];
    if (gFRotorZeroed) [tables addObject:gFRotorZeroed];
    for (NSArray *tb in tables) {
        for (FCFlattenRecord *rec in tb) {
            if (!rec.zeroCollapsed || !rec.view) continue;
            if (!rec.view.window) continue;   // v47：已离树的不算留白（否则数字虚高）
            if (FCViewHasZeroedAncestor(rec.view)) continue;
            h += rec.originalFrame.size.height;
        }
    }
    return h;
}

// v32：每轮扫描开头重新施加所有压0压制——DX 引擎下一帧重设 frame 后由这里压回。
// 这是压0模式能对抗「重绘复现」的核心：节点一直在树里，扫描器每轮都能找到它。
static void FCReapplyAllZeroFrames(void) {
    // v44：大块免压开关打开后，把「已经压掉的」大块逐步还原。
    // 不做这一步，开关只对「新命中」生效，之前压的 155pt 大位照样留着白——等于没开。
    if (FCBigBlockPassOn()) {
        NSMutableArray *tables = [NSMutableArray array];
        if (gFCFlattened) [tables addObject:gFCFlattened];
        if (gFCSourceZeroed) [tables addObject:gFCSourceZeroed];
        if (gFCShellZeroed) [tables addObject:gFCShellZeroed];
        if (gFRotorZeroed) [tables addObject:gFRotorZeroed];
        NSUInteger restored = 0;
        for (NSMutableArray *tb in tables) {
            NSMutableArray *gone = [NSMutableArray array];
            for (FCFlattenRecord *rec in [tb copy]) {
                if (rec.originalFrame.size.height <= kFCBigBlockH) continue;
                @try {
                    FCRestoreZeroRecord(rec);
                    if (rec.view) rec.view.hidden = NO;
                } @catch (NSException *e) { }
                [gone addObject:rec];
                restored++;
            }
            [tb removeObjectsInArray:gone];
        }
        if (restored) FCLog(@"大块免压：还原 %lu 处已压大位", (unsigned long)restored);
    }
    for (FCFlattenRecord *rec in gFCFlattened) {
        if (rec.zeroCollapsed && rec.view) {
            CGRect f = rec.view.frame;
            if (f.size.width > 0.5 || f.size.height > 0.5 || rec.view.alpha > 0.01) {
                FCForceZeroFrame(rec.view);
                gFCZeroApplied++;
            }
        }
    }
    // v34：源头命中模板的 DXRootView 容器也每轮重压——对抗 DX 重设 frame。
    for (FCFlattenRecord *rec in gFCSourceZeroed) {
        if (rec.view) {
            CGRect f = rec.view.frame;
            if (f.size.width > 0.5 || f.size.height > 0.5 || rec.view.alpha > 0.01) {
                FCForceZeroFrame(rec.view);
                gFCZeroApplied++;
            }
        }
    }
    // v37：源头坑位外层空壳 cell 每轮重压——UICollectionView 复用会重设 cell 的 frame/alpha。
    for (FCFlattenRecord *rec in gFCShellZeroed) {
        if (rec.view) {
            CGRect f = rec.view.frame;
            if (f.size.width > 0.5 || f.size.height > 0.5 || rec.view.alpha > 0.01) {
                FCForceZeroFrame(rec.view);
                gFCZeroApplied++;
            }
        }
    }
    // v38：轮播空壳 cell 每轮重压——同样对抗 UICollectionView 复用重设 frame。
    for (FCFlattenRecord *rec in gFRotorZeroed) {
        if (rec.view) {
            CGRect f = rec.view.frame;
            if (f.size.width > 0.5 || f.size.height > 0.5 || rec.view.alpha > 0.01) {
                FCForceZeroFrame(rec.view);
                gFCZeroApplied++;
            }
        }
    }
}

// v16：检查已塌陷的 view——规则还在就保持移除，规则删了就插回原位（可逆）
// v32：压0模式规则失效时用 FCRestoreZeroRecord 还原 frame，旧移除模式仍走插回。
static void FCRestoreFlattenedIfNeeded(NSArray<NSString *> *rules) {
    if (!gFCFlattened.count) return;
    NSMutableArray *gone = [NSMutableArray array];
    for (FCFlattenRecord *rec in gFCFlattened) {
        BOOL still = FCRecordRuleStillValid(rec, rules);
        if (rec.zeroCollapsed) {
            // 压0模式：规则还在则保持；失效则还原（view 已从树里被移除也还原）
            if (!still || !rec.view) [gone addObject:rec];
            continue;
        }
        if (!still || !rec.superview) [gone addObject:rec];
    }
    for (FCFlattenRecord *rec in gone) {
        if (rec.zeroCollapsed) {
            FCRestoreZeroRecord(rec);
        } else if (rec.superview) {
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
    FCPruneSourceZeros();                  // v34：源头压0复用自愈——模板变了就还原，防误伤正常卡片
    FCPruneBlockedCellShells();            // v37：外壳 cell 复用自愈——坑位内容恢复正常就还原外壳
    FCPruneRotorCells();                   // v38：轮播空壳自愈——内部冒出正常文字就还原（独立口径）
    FCReapplyAllZeroFrames();              // v32：每轮重新压制——对抗 DX 重设 frame
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
            // v34：源头模板压0——hook 触发时容器可能还没布局，故在扫描阶段「有尺寸、在树里」时补压。
            // 判定逻辑封装在 FCZeroSourceRootIfBlocked（定义在 bridge/tpl 判定之后），内部幂等。
            if ([v isKindOfClass:NSClassFromString(@"DXRootView")]) {
                FCZeroSourceRootIfBlocked(v);
                // v37：源头拦截(kFCBlockedRoot)或源头压0(kFCZeroRec)命中的 root → 向上塌陷承载它的
                // AliIFDXCollectionViewCell 空壳（内容没了但 cell 仍占满宽高度=白块）。
                // 只认 DXRootView 级标记：商品流 recommend_* 无此痕迹，绝不误伤。
                if (objc_getAssociatedObject(v, &kFCBlockedRoot) ||
                    objc_getAssociatedObject(v, &kFCZeroRec)) {
                    FCZeroBlockedCellShell(v);
                    // v40：压子视图只删内容不减高度（v35/v39 两版商品流起点都在 y≈590 铁证），
                    // 真正的 480pt 高度由 DX 高度规格/宿主 item 决定。这里从布局源头归零：
                    // 高度规格置 0 + 通知宿主 collection 重排，让容器自己塌下去。
                    FCZeroDXHeightSpec(v);
                }
            }
            // v40：v39 的「几何空壳」压0 已证实无效（压子视图不减高度）且会误伤正常运营位，
            // 用常量开关停用（代码与自愈保留，便于回退）。白块改由 FCZeroDXHeightSpec 从布局层解决。
            if (gFCRotorEnabled) FCZeroRotorCellIfEmpty(v);
            // v32：已被本插件压0的元素——每轮重新压制已由 FCReapplyAllZeroFrames 统一处理，
            // 这里直接跳过命中判定，避免 alpha=0/frame=0 的元素反复计数或误判，但仍下钻子视图。
            if (objc_getAssociatedObject(v, &kFCZeroRec)) {
                for (UIView *sub in v.subviews) [q addObject:sub];
                continue;
            }
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
            if (v.hidden) { for (UIView *sub in v.subviews) [q addObject:sub]; continue; }
            // v23 紧急修黑屏：v22 让「用户硬命中」绕过全部闸门（含 height>50%屏），
            // 结果点选存的 cls: 祖先链规则命中页面根容器 → 整块塌陷 → 整页黑屏（真机原17）。
            // 大容器闸门必须无条件生效——这是防黑屏底线，任何规则都不得移除半屏以上的 view。
            // v46：但 v23 的写法是「高>50%屏 **或** 宽>95%屏」，宽度单独一条就跳 →
            // **所有满宽容器（我的淘宝每个板块都是 430pt 满宽，如 430x142 的领券中心）
            // 任何规则都命中不了**，表现为「点选时藏起来了、退出点选又原样回来」（真机 v45）。
            // 改成「超高，或又宽又高」才跳：单满宽但矮（<35%屏）不可能是页面根，也不会造成黑屏。
            {
                CGFloat sw0 = [UIScreen mainScreen].bounds.size.width;
                BOOL tooWide = r.size.width > sw0 * 0.95;
                if (r.size.height > sh * 0.5 || (tooWide && r.size.height > sh * 0.35)) {
                    for (UIView *sub in v.subviews) [q addObject:sub];
                    continue;
                }
            }
            // v22：小元素（height<18 / width<40）若被用户明确点选的规则硬命中，仍允许隐藏，
            // 解决真机 130x17 的「领券中心」被跳过的问题。内置词不算硬命中。
            BOOL userHardHit = NO;
            for (NSString *rule in rules) {
                if (FCIsBuiltinAdKey(rule)) continue;
                if (rule.length >= 5 && [rule isEqualToString:vcls]) { userHardHit = YES; break; }
                if (FCRuleMatchesFingerprint(rule, vcls, r, [UIScreen mainScreen].bounds.size.width, sh)) {
                    userHardHit = YES; break;
                }
            }
            if (!userHardHit && (r.size.width < 40 || r.size.height < 18)) {
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
                    // v42：计数去重——同一节点每轮都会走到这里，旧写法让「挡」每 tick 上涨。
                    // 弱表按节点记一次，数字才代表「被闸门挡下的节点数」而非「挡了多少轮」。
                    gFCBuiltinBlocked++;
                    if (!gFCBlockedSeen) gFCBlockedSeen = [NSHashTable weakObjectsHashTable];
                    if (![gFCBlockedSeen containsObject:v]) {
                        [gFCBlockedSeen addObject:v];
                        gFCBlockedUnique++;
                    }
                    for (UIView *sub in v.subviews) [q addObject:sub];
                    continue;
                }
                gFCNativeHits++;
                if (builtinHit) gFCBuiltinHits++;
                // v25：塌陷移除整块卡片外壳——真机命中文字 label 后只删 label，外层带背景
                // 的卡片容器还在 → 留白方块。改为移除 FCCardShellForHide 找到的整块卡片。
                // 用记录表保住 view（否则释放），规则删除时 FCRestoreFlattenedIfNeeded 插回。
                UIView *target = FCCardShellForHide(v);
                // v45：命中点若是落在表格行里，升级成「整行」再压——只压那行文字的话，
                // 文字没了、行高 142pt 还在，浮标显示「规则命中 1」但页面上一片白
                // （老大连着几版反馈「去不掉」的真身）。守卫：行不能太高、不能塞满正常内容。
                {
                    UITableViewCell *rowCell = FCEnclosingRowCell(target);
                    if (rowCell) {
                        CGRect rr = [rowCell convertRect:rowCell.bounds toView:nil];
                        CGFloat shh = [UIScreen mainScreen].bounds.size.height;
                        if (rr.size.height <= shh * 0.45 && FCCellLiveTextCount(rowCell, 0) <= 12) {
                            target = rowCell;
                        }
                    }
                }
                // v43：大块免压——超过阈值就不压，整枝也不再往下扫（否则压一堆小的同样留白）
                {
                    CGRect tr = target ? [target convertRect:target.bounds toView:nil] : CGRectZero;
                    if (FCShouldSkipBigBlockFor(tr, target)) {
                        FCLog(@"大块免压(规则): %@ %.0fpt > %.0f",
                              NSStringFromClass([target class]), tr.size.height, kFCBigBlockH);
                        continue;
                    }
                }
                UIView *targetParent = target.superview;   // v26：移除后用于空壳父容器判定
                BOOL alreadyFlattened = NO;
                for (FCFlattenRecord *rec in gFCFlattened) if (rec.view == target) { alreadyFlattened = YES; break; }
                if (target.superview && !alreadyFlattened) {
                    FCFlattenRecord *rec = [FCFlattenRecord new];
                    rec.view = target;
                    rec.superview = target.superview;
                    rec.index = [target.superview.subviews indexOfObject:target];
                    rec.rule = hitRule ?: @"";
                    // v32：压0塌陷——节点留在视图树，只把尺寸压成0，DX 重绘由每轮 FCReapplyAllZeroFrames 压回。
                    // 关键：不再 removeFromSuperview（那会让扫描器找不到节点、且 DX 重建复现）。
                    rec.zeroCollapsed = YES;
                    rec.originalFrame = target.frame;
                    rec.originalAlpha = target.alpha;
                    rec.originalClips = target.clipsToBounds;
                    [gFCFlattened addObject:rec];
                    objc_setAssociatedObject(target, &kFCZeroRec, rec, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    FCForceZeroFrame(target);
                    gFCZeroApplied++;
                    // v45：压的是整行就登记行高归零——否则内容没了、行高还在 = 白块
                    FCMarkRowZero(target);
                    // v26：若父容器被删空（只剩背景无文字），连同空壳一起移除，消除留白框
                    FCRemoveEmptyShellIfNeeded(targetParent, hitRule);
                    // 父视图是 stack/collection 时触发布局重算，下方元素自动补齐
                    if ([targetParent isKindOfClass:NSClassFromString(@"UIStackView")] ||
                        [targetParent isKindOfClass:[UIScrollView class]]) [targetParent setNeedsLayout];
                } else {
                    // v32：无父视图时兜底——仍用压0（不 remove），保持与压0模式一致的可逆性
                    FCFlattenRecord *rec = [FCFlattenRecord new];
                    rec.view = target; rec.rule = hitRule ?: @""; rec.zeroCollapsed = YES;
                    rec.originalFrame = target.frame; rec.originalAlpha = target.alpha;
                    rec.originalClips = target.clipsToBounds;
                    [gFCFlattened addObject:rec];
                    objc_setAssociatedObject(target, &kFCZeroRec, rec, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    FCForceZeroFrame(target);
                    gFCZeroApplied++;
                }
            }
            for (UIView *sub in v.subviews) [q addObject:sub];
        }
    }
}

// v47：清掉「视图已经不在窗口里」的压0记录。
// 为什么必须清：rec.view 是强引用 → 被压过的 DX cell 被复用完离树后，记录仍攥着它，
// 越积越多（真机 v46 诊断里 311 条），于是浮标「压」一直涨、留白估算也虚高。
// 只按「是否还在窗口里」判断，合理：真需要的节点下一轮扫描会重新压并重建记录。
static void FCPruneDeadFlattenRecords(void) {
    if (!gFCFlattened.count) return;
    NSMutableArray *dead = [NSMutableArray array];
    for (FCFlattenRecord *rec in gFCFlattened) {
        UIView *v = rec.view;
        if (!v || !v.window) [dead addObject:rec];
    }
    if (dead.count) [gFCFlattened removeObjectsInArray:dead];
}

static void FCScanOnce(void) {
    // v42：暂停拦截 / 点选冻结期间完全不扫——不压0、不隐藏、不拦模板。
    // 这是「无法选择广告元素」的根治：不扫就不会把用户想点的那块压掉。
    if (gFCPaused || gFCPickFreeze) { gFCWindows = FCAllWindows().count; return; }
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
    // v45：行高归零登记的自愈——行号对应的 cell 换人了（数据刷新/复用）就撤销，避免压掉正常行
    FCPruneRowMarks();
    // v47：清掉失效压0记录——否则「压」的数字只涨不跌（记录攥着已离树的 DX cell）
    FCPruneDeadFlattenRecords();
    // v41：把本 tick 里入队的宿主重排放到扫描末尾统一做——定时器回调里执行，
    // 不在任何 UIKit update 事务中，避免 v40 那种「cell 配置期重入布局 → 野指针」闪退。
    FCPerformPendingRelayout();
}

#pragma mark - 找触点下最底层 view / 原生容器

static UIView *FCHitViewAtPoint(CGPoint p) {
    UIView *found = nil;
    for (UIWindow *w in FCAllWindows()) {
        NSString *wc = NSStringFromClass([w class]);
        if ([wc isEqualToString:@"FCBadgeWindow"] || [wc isEqualToString:@"FCPanelWindow"] || [wc isEqualToString:@"FCDiagWindow"]) continue;
        // v45：键盘/输入窗口整窗跳过——真机证据：我的淘宝点「超级88领券中心」被某个
        // 键盘类窗口里看不见的 UIInputSetContainerView 抢走命中，直接报「是键盘容器」，
        // 一次规则都没存，表现为「怎么点都去不掉」。扫描侧早就跳过这些窗口，点选侧漏了。
        if ([wc hasPrefix:@"UITextEffects"] || [wc hasPrefix:@"UIRemoteKeyboard"] ||
            [wc hasPrefix:@"_UI"] || [wc rangeOfString:@"Input"].location != NSNotFound ||
            [wc rangeOfString:@"Keyboard"].location != NSNotFound) continue;
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
    // v24：穿透空壳 WKWebView——真机淘宝满屏 WKWebView(frame 0,0 430x932, DOM空)的内部
    // WKScrollView 会盖住真正的 DX 运营位，导致点选判成 H5、JS 拾取失败、降级又被 webInternal
    // 拦死。若 hit 在 WK 内部，收集同坐标下所有深层 view，优先取引擎为 DX/RN/Flutter 的宿主
    // view 替换 hit；找不到则保持原样（真 H5 页面下面没有 DX view，不受影响）。
    NSString *hitCls = found ? NSStringFromClass([found class]) : @"";
    BOOL hitIsWK = [hitCls hasPrefix:@"WK"] || [hitCls rangeOfString:@"WebView"].location != NSNotFound;
    if (hitIsWK) {
        // v42：穿透放宽。旧逻辑只认 DX/RN/Flutter/小程序四种引擎的宿主，淘宝首页
        // 满屏空壳 WKWebView（frame 0,0 430x932，DOM 空）下面若没有这四种 view、
        // 或者它们已被压成 0 尺寸，就退不出去 → 走网页通道 → 报「网页拾取失败」，
        // 表现为「无法选择广告元素」。现在分两档：
        //   ①优先：引擎是动态化的宿主（最准，规则存得对）；
        //   ②兜底：任意非 WK、非系统私有、尺寸正常的业务 view，取层级最深的一个。
        UIView *bestEngine = nil; NSUInteger bestEngineDepth = 0;
        UIView *bestAny = nil;    NSUInteger bestAnyDepth = 0;
        CGFloat scrArea = [UIScreen mainScreen].bounds.size.width *
                          [UIScreen mainScreen].bounds.size.height;
        for (UIWindow *w in FCAllWindows()) {
            NSString *wc = NSStringFromClass([w class]);
            if ([wc isEqualToString:@"FCBadgeWindow"] || [wc isEqualToString:@"FCPanelWindow"] ||
                [wc isEqualToString:@"FCDiagWindow"]) continue;
            // v45：与主命中循环同口径，键盘/输入窗口整窗跳过
            if ([wc hasPrefix:@"UITextEffects"] || [wc hasPrefix:@"UIRemoteKeyboard"] ||
                [wc hasPrefix:@"_UI"] || [wc rangeOfString:@"Input"].location != NSNotFound ||
                [wc rangeOfString:@"Keyboard"].location != NSNotFound) continue;
            if (w.hidden || w.alpha < 0.01) continue;
            NSMutableArray<UIView *> *st = [NSMutableArray arrayWithObject:w];
            NSMutableArray<NSNumber *> *dps = [NSMutableArray arrayWithObject:@0];
            while (st.count) {
                UIView *v = st.lastObject; [st removeLastObject];
                NSUInteger d = dps.lastObject.unsignedIntegerValue; [dps removeLastObject];
                if (v.hidden || v.alpha < 0.05 || v.tag == 9527 || v.tag == 9528) continue;
                CGRect vr = [v convertRect:v.bounds toView:nil];
                if (!CGRectContainsPoint(vr, p)) continue;
                NSString *vc = NSStringFromClass([v class]);
                BOOL vIsWK = [vc hasPrefix:@"WK"] || [vc rangeOfString:@"WebView"].location != NSNotFound;
                BOOL priv = [vc hasPrefix:@"_UI"] || [vc hasPrefix:@"UIInput"] || [vc hasPrefix:@"UIKeyboard"];
                if (!vIsWK) {
                    FCEngine e = FCEngineOfClass(vc);
                    if (e == FCEngineDX || e == FCEngineRN || e == FCEngineFlutter || e == FCEngineMiniApp) {
                        if (d >= bestEngineDepth) { bestEngine = v; bestEngineDepth = d; }
                    }
                    // 兜底候选：尺寸真实存在、不占满屏（占满屏基本是页面根容器）、非系统私有
                    BOOL realSize = vr.size.width >= 8 && vr.size.height >= 8;
                    BOOL notRoot = vr.size.width < [UIScreen mainScreen].bounds.size.width * 0.92 ||
                                   vr.size.height < [UIScreen mainScreen].bounds.size.height * 0.92;
                    if (!priv && realSize && notRoot && vr.size.width * vr.size.height < scrArea * 0.85 &&
                        d >= bestAnyDepth) { bestAny = v; bestAnyDepth = d; }
                }
                for (UIView *sv in v.subviews) { [st addObject:sv]; [dps addObject:@(d + 1)]; }
            }
        }
        if (bestEngine) found = bestEngine;
        else if (bestAny) found = bestAny;
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

// v26：删除目标——只删「命中内容自身」，不再猜外层大容器。
// 真机教训（v25/v26 猜容器整块删）：诊断显示命中✓的元素仍在树里可见 → 我们删的是猜出来的
// DX 外层容器，而阿里 DX 动态化引擎下一帧就重绘恢复，进入「删→重绘→再删」打架状态，
// 表现为留白框/时有时无。正解：删命中元素自身（粒度精确、不碰 DX 管理的容器）。
// 仅当命中元素很小（高<40，通常是个文字 label）时，连同它的直接父容器一起删——
// 直接父容器粒度适中，既吃掉小 label 的外壳，又不会猜到会被重绘的大卡片。
static UIView *FCCardShellForHide(UIView *hit) {
    return hit;   // 默认：删命中自身。空壳父容器清理交给下方的 FCRemoveEmptyShellIfNeeded。
}

// v33：删掉命中元素后，压掉它上方变成「空壳」的坑位容器——专治 secondfloor 大白块。
// 【v32 漏判根因】v32 只查直接父一层、且高度上限 30%屏；真机大白块约 35%屏(325pt)、
// 且命中文字往往隔了 2~3 层容器才到撑高度的坑位 → 两个条件都把它挡在外面，于是
// 「文字压0了、坑位容器还占着一大块高度」= 截图里搜索栏下方的纯白空白。
// 【v33 改法】从 removedFrom 向上最多 3 层逐层判空壳，高度上限放宽到 45%屏；
// 但黑屏底线不破：①仍远低于 50%屏硬闸门；②必须真·空壳（自身无文字 + 可见子 view≤1
// 且子 view 有实际尺寸）；③遇 TabBar/NavigationBar/UIWindow/非空壳容器立即停，
// 绝不猜到页面根容器。满足则压0（节点留树、每轮重压），下方内容自然补齐。
static void FCRemoveEmptyShellIfNeeded(UIView *removedFrom, NSString *rule) {
    UIView *p = removedFrom;
    CGFloat sh = [UIScreen mainScreen].bounds.size.height;
    CGFloat sw = [UIScreen mainScreen].bounds.size.width;
    for (int up = 0; p && up < 3; up++) {
        if ([p isKindOfClass:[UIWindow class]]) break;
        NSString *pcls = NSStringFromClass([p class]);
        if ([pcls rangeOfString:@"TabBar"].location != NSNotFound ||
            [pcls rangeOfString:@"NavigationBar"].location != NSNotFound) break;
        CGRect pr = [p convertRect:p.bounds toView:nil];
        // 黑屏底线：超过 45%屏的容器绝不碰（50%屏是扫描器硬闸门，这里留 5%缓冲）
        if (pr.size.height > sh * 0.45 || pr.size.width > sw * 0.95) break;
        // 空壳判定：自身无文字 + 可见且有尺寸的子 view≤1 + 尺寸像块卡片
        NSString *ownText = FCOwnTextOf(p);
        NSUInteger visibleSubs = 0;
        for (UIView *s in p.subviews)
            if (!s.hidden && s.alpha >= 0.05 && s.frame.size.width > 0.5 && s.frame.size.height > 0.5) visibleSubs++;
        if (ownText.length != 0 || visibleSubs > 1 || pr.size.width < 100 || pr.size.height < 30) break;
        BOOL already = NO;
        for (FCFlattenRecord *rec in gFCFlattened) if (rec.view == p) { already = YES; break; }
        if (p.superview && !already) {
            FCFlattenRecord *rec = [FCFlattenRecord new];
            rec.view = p; rec.superview = p.superview;
            rec.index = [p.superview.subviews indexOfObject:p];
            rec.rule = rule ?: @"";
            // 节点留树里压0，DX 重绘由每轮 FCReapplyAllZeroFrames 压回；规则删除时可逆还原。
            rec.zeroCollapsed = YES;
            rec.originalFrame = p.frame;
            rec.originalAlpha = p.alpha;
            rec.originalClips = p.clipsToBounds;
            [gFCFlattened addObject:rec];
            objc_setAssociatedObject(p, &kFCZeroRec, rec, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            FCForceZeroFrame(p);
            gFCZeroApplied++;
            FCLog(@"空壳压0(上%d层)：%@ %.0fx%.0f", up, pcls, pr.size.width, pr.size.height);
        }
        p = p.superview;   // 继续向上一层，直到非空壳/过大/到顶
    }
}

#pragma mark - 点选拾取

// v18：原生拾取——从触点 hit 往上找运营卡片，存「文案 + cls:宿主类 + pos:位置」指纹。
// 抽成函数供两条路径复用：①无 webview 直接走；②网页 JS 失败(MISS/TOOBIG/err)降级走。
// v29：从 DXRootView.setData: 的参数字典取模板名——真机证据 data.template.name/version
// 兼容两种结构：①参数本身含 template 键；②参数外层 data.template（实际取证是后者）
static NSString *FCTplNameFromData(id raw) {
    if (![raw isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *d = (NSDictionary *)raw;
    NSDictionary *t = d[@"template"];
    // v30：真机取证——多数卡片模板名在 data.style.template（22键那批），不是顶层 template
    if (![t isKindOfClass:[NSDictionary class]]) {
        NSDictionary *style = d[@"style"];
        if ([style isKindOfClass:[NSDictionary class]]) t = style[@"template"];
    }
    if (![t isKindOfClass:[NSDictionary class]]) {
        NSDictionary *inner = d[@"data"];
        if ([inner isKindOfClass:[NSDictionary class]]) {
            t = inner[@"template"];
            if (![t isKindOfClass:[NSDictionary class]]) {
                NSDictionary *is = inner[@"style"];
                if ([is isKindOfClass:[NSDictionary class]]) t = is[@"template"];
            }
        }
    }
    if (![t isKindOfClass:[NSDictionary class]]) return nil;
    NSString *name = t[@"name"];
    if (![name isKindOfClass:[NSString class]] || !name.length || name.length > 120) return nil;
    id verRaw = t[@"version"];
    NSString *ver = nil;
    if ([verRaw isKindOfClass:[NSNumber class]]) ver = [(NSNumber *)verRaw stringValue];
    else if ([verRaw isKindOfClass:[NSString class]]) ver = (NSString *)verRaw;
    if (ver.length > 12) ver = nil;
    // 完整名 = name_version（与 setTemplateItem 对象名一致，如 secondfloor_10）
    return ver.length ? [NSString stringWithFormat:@"%@_%@", name, ver] : name;
}

// v29：从 DXTemplateItem 的 description 抠完整模板名（<0x.. DXTemplateItem:xxx>）
static NSString *FCTplNameFromItem(id item) {
    if (!item) return nil;
    NSString *d = [item description];
    NSRange r = [d rangeOfString:@"DXTemplateItem:"];
    if (r.location == NSNotFound) return nil;
    NSString *rest = [d substringFromIndex:NSMaxRange(r)];
    NSRange e = [rest rangeOfString:@">"];
    if (e.location != NSNotFound) rest = [rest substringToIndex:e.location];
    rest = [rest stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    return (rest.length && rest.length <= 160) ? rest : nil;
}

// v30：bridge 映射——Deep 档 hook 在 setTemplateItem:/setData: 时把「DXRootView 实例 → 模板名」
// 记下来。点选时直接查表，不再依赖 KVC 读 Swift/ObjC 混合的 data 属性（很可能读不到）。
static NSMapTable<UIView *, NSString *> *gFCTplBridge = nil;

static void FCTplBridgePut(UIView *view, NSString *name) {
    if (!view || !name.length) return;
    if (!gFCTplBridge) gFCTplBridge = [NSMapTable weakToStrongObjectsMapTable];
    [gFCTplBridge setObject:name forKey:view];
}

// v29/v30：点选命中元素向上找承载它的 DXRootView，取该卡片正在渲染的模板名
static NSString *FCTemplateNameOfView(UIView *v) {
    Class dxRoot = NSClassFromString(@"DXRootView");
    if (!dxRoot) return nil;
    UIView *cur = v;
    for (int depth = 0; cur && depth < 30; depth++) {
        if ([cur isKindOfClass:dxRoot]) {
            // v30 首选：hook 建立的实例映射，最可靠
            NSString *n = gFCTplBridge ? [gFCTplBridge objectForKey:cur] : nil;
            if (n.length) return n;
            @try { n = FCTplNameFromData([cur valueForKey:@"data"]); } @catch (NSException *e) { }
            if (n.length) return n;
            @try { n = FCTplNameFromItem([cur valueForKey:@"templateItem"]); } @catch (NSException *e) { }
            if (n.length) return n;
        }
        cur = cur.superview;
    }
    return nil;
}

// v30：内置身份型广告模板——真机取证铁证，服务端改文案不改模板身份。
// 用「核心身份子串」而非完整名，避开版本号（67/72 会随服务端升级变化）。
static BOOL FCTplBuiltinBlocked(NSString *tpl) {
    if (!FCBuiltinEnabled() || !tpl.length) return NO;   // 尊重「内置规则开关」
    static NSArray *ids = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ ids = @[
        @"88_campaign",           // 超级88 领券中心（老大反复要去掉的）
        @"campaign_bottom_bar",   // 首页底部活动条
        // v34：搜索栏下方运营坑位（轮播+天猫入口），真机取证 second_pit_searchbar_slim。
        @"second_pit",            // 搜索栏下方小坑位（v34 拦了但白块没塌）
        // v35：白块真凶修正——撑高度的是 secondfloor（secondfloor_10 / secondfloor.zip），
        // 不是 second_pit。v34 误把 secondfloor 当「首页信息流容器」故没拦，白块纹丝不动。
        // 真机取证：商品信息流是 recommend_* 系列（recommend_m_home_*/recommend_newface_*），
        // 与 secondfloor 是两个独立模板；拦 secondfloor 不会动商品流。老大已授权「拦+压」。
        @"secondfloor",           // 搜索栏下方运营楼层（白块主体，约470pt）
    ]; });
    for (NSString *key in ids)
        if ([tpl rangeOfString:key].location != NSNotFound) return YES;
    return NO;
}

// v29：tpl: 规则判定——支持「完整名」与「name_version」两种存法互相兼容
static BOOL FCTplIsBlocked(NSString *tpl) {
    if (!tpl.length) return NO;
    if (FCTplBuiltinBlocked(tpl)) return YES;            // v30：内置身份模板
    for (NSString *r in FCUserRules()) {
        if (![r hasPrefix:@"tpl:"]) continue;
        NSString *want = [r substringFromIndex:4];
        if (!want.length) continue;
        if ([want isEqualToString:tpl]) return YES;
        // 点选存的若是 name、数据是 name_version（或反之），只在尾段为纯数字版本时兼容
        NSString *longer = want.length > tpl.length ? want : tpl;
        NSString *shorter = want.length > tpl.length ? tpl : want;
        if (longer.length > shorter.length && [longer hasPrefix:shorter]) {
            NSString *tail = [longer substringFromIndex:shorter.length];
            if (tail.length >= 2 && tail.length <= 5 && [tail hasPrefix:@"_"]) {
                NSString *num = [tail substringFromIndex:1];
                BOOL digit = num.length > 0;
                NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
                for (NSUInteger i = 0; i < num.length; i++)
                    if (![digits characterIsMember:[num characterAtIndex:i]]) { digit = NO; break; }
                if (digit) return YES;
            }
        }
    }
    return NO;
}

// v34：把命中的 DXRootView 容器压0（节点留树里，每轮 FCReapplyAllZeroFrames 重压）。
// 只在扫描阶段「有尺寸、在树里」时调用——hook 触发时容器可能还没布局。
static void FCZeroSourceRoot(UIView *root, NSString *tpl) {
    if (!root || !root.superview || !tpl.length) return;
    CGRect r = [root convertRect:root.bounds toView:nil];
    if (r.size.width < 1 || r.size.height < 1) return;   // 还没布局，交给下一轮
    // v43：大块免压——源头容器往往就是 135/155pt 的活动卡，压了必留一大片白
    // v45：能归零的表格行不算留白（FCRowZeroCapable），放行
    if (FCShouldSkipBigBlockFor(r, root)) {
        FCLog(@"大块免压(源头): %@ %.0fpt", tpl, r.size.height);
        return;
    }
    if (!gFCSourceZeroed) gFCSourceZeroed = [NSMutableArray array];
    for (FCFlattenRecord *rec in gFCSourceZeroed) if (rec.view == root) return;  // 已压，幂等
    FCFlattenRecord *rec = [FCFlattenRecord new];
    rec.view = root; rec.superview = root.superview;
    rec.index = [root.superview.subviews indexOfObject:root];
    rec.rule = [@"tpl:" stringByAppendingString:tpl];
    rec.zeroCollapsed = YES;
    rec.originalFrame = root.frame;
    rec.originalAlpha = root.alpha;
    rec.originalClips = root.clipsToBounds;
    [gFCSourceZeroed addObject:rec];
    objc_setAssociatedObject(root, &kFCZeroRec, rec, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    FCForceZeroFrame(root);
    gFCZeroApplied++;
    FCLog(@"源头压0容器: %@ %.0fx%.0f", tpl, r.size.width, r.size.height);
}

// v34：扫描阶段——从 bridge 取该 DXRootView 的模板名，命中 tpl:/内置身份模板就压0容器。
// 放在这里确保 gFCTplBridge / FCTplIsBlocked 已定义，避免隐式声明。
static void FCZeroSourceRootIfBlocked(UIView *v) {
    NSString *tpl = gFCTplBridge ? [gFCTplBridge objectForKey:v] : nil;
    if (tpl.length && FCTplIsBlocked(tpl)) FCZeroSourceRoot(v, tpl);
}

// v34：每轮开头清理失效的源头压0——容器离树、或 bridge 模板已不命中（复用渲染正常卡片）→还原。
// 只在「明确读到新模板名且不命中」时才还原，瞬时读不到则保持压制，避免误放。
static void FCPruneSourceZeros(void) {
    if (!gFCSourceZeroed.count) return;
    NSMutableArray *gone = [NSMutableArray array];
    for (FCFlattenRecord *rec in gFCSourceZeroed) {
        UIView *v = rec.view;
        if (!v || !v.superview) { [gone addObject:rec]; continue; }
        NSString *now = gFCTplBridge ? [gFCTplBridge objectForKey:v] : nil;
        if (now.length && !FCTplIsBlocked(now)) {
            FCRestoreZeroRecord(rec);
            [gone addObject:rec];
        }
    }
    [gFCSourceZeroed removeObjectsInArray:gone];
}

// ===== v37：源头坑位外层空壳 cell 塌陷 =====
// 真机铁证（v36 诊断交叉印证）：白块候选 AliIFDXCollectionViewCell 0,400 430x135（压:否 tpl:-），
// 与压0清单·源 DXRootView 原0,0 430x135→0x0（88_campaign）尺寸完全吻合——同一坑位内外两层。
// 源头拦/压0只作用于内部 DXRootView，外层 cell 仍占满宽高度=白块。
// 防误伤核心：只从「我们亲自拦/压过的 root」向上找 cell；商品流 recommend_* 无痕迹，绝不触发。
static BOOL FCCellStillHasBlockedTrace(UIView *cell, int depth) {
    if (!cell || depth > 10) return NO;
    Class dxRoot = NSClassFromString(@"DXRootView");
    for (UIView *s in cell.subviews) {
        if (dxRoot && [s isKindOfClass:dxRoot]) {
            if (objc_getAssociatedObject(s, &kFCBlockedRoot)) return YES;
            NSString *tpl = gFCTplBridge ? [gFCTplBridge objectForKey:s] : nil;
            if (tpl.length && FCTplIsBlocked(tpl)) return YES;
        }
        if (FCCellStillHasBlockedTrace(s, depth + 1)) return YES;
    }
    return NO;
}

// cell 内「有效可见内容」文字条数——被本插件压0/拦截的节点整枝不算。
// 双保险：万一误触发，含正常内容的 cell（商品流）也不会被压。
static NSUInteger FCCellLiveTextCount(UIView *v, int depth) {
    if (!v || depth > 10) return 0;
    if (objc_getAssociatedObject(v, &kFCZeroRec) || objc_getAssociatedObject(v, &kFCBlockedRoot)) return 0;
    NSUInteger n = 0;
    if (!v.hidden && v.alpha >= 0.05 && v.frame.size.width > 1 && v.frame.size.height > 1 &&
        FCOwnTextOf(v).length) n++;
    for (UIView *s in v.subviews) n += FCCellLiveTextCount(s, depth + 1);
    return n;
}

static void FCZeroBlockedCellShell(UIView *root) {
    if (!root || !root.superview) return;
    // 再校验一次痕迹，防止误调用（源头拦截=kFCBlockedRoot / 源头压0=bridge模板命中）
    BOOL trace = objc_getAssociatedObject(root, &kFCBlockedRoot) != nil;
    NSString *tpl = gFCTplBridge ? [gFCTplBridge objectForKey:root] : nil;
    if (tpl.length && FCTplIsBlocked(tpl)) trace = YES;
    if (!trace) return;
    // 从 root 向上最多 4 层找诊断实证的外层 cell 类（精确类名，不碰普通 UICollectionViewCell）
    UIView *cell = nil;
    UIView *cur = root.superview;
    Class shellCls = NSClassFromString(@"AliIFDXCollectionViewCell");
    for (int up = 0; cur && up < 4; up++) {
        if (shellCls && [cur isKindOfClass:shellCls]) { cell = cur; break; }
        cur = cur.superview;
    }
    if (!cell || !cell.superview) return;
    // 尺寸闸门：满宽坑位、高度 80~32%屏（白块 135/155），远低于 50% 黑屏硬线
    CGRect r = [cell convertRect:cell.bounds toView:nil];
    CGFloat sh = [UIScreen mainScreen].bounds.size.height;
    CGFloat sw = [UIScreen mainScreen].bounds.size.width;
    if (r.size.width < sw * 0.75 || r.size.height < 80 || r.size.height > sh * 0.32) return;
    // v43：大块免压——外壳 cell 就是最终留白的那一层，压了直接换回等高的白
    if (FCShouldSkipBigBlockFor(r, cell)) {
        FCLog(@"大块免压(外壳): %@ %.0fpt", NSStringFromClass([cell class]), r.size.height);
        return;
    }
    // 空壳判定：除被拦内容外若还有 >2 条有效文字，说明 cell 里有正常内容，不压（双保险）
    if (FCCellLiveTextCount(cell, 0) > 2) return;
    if (!gFCShellZeroed) gFCShellZeroed = [NSMutableArray array];
    for (FCFlattenRecord *rec in gFCShellZeroed) if (rec.view == cell) return;  // 幂等
    FCFlattenRecord *rec = [FCFlattenRecord new];
    rec.view = cell; rec.superview = cell.superview;
    rec.index = [cell.superview.subviews indexOfObject:cell];
    rec.rule = @"源头坑位外壳";
    rec.zeroCollapsed = YES;
    rec.originalFrame = cell.frame;
    rec.originalAlpha = cell.alpha;
    rec.originalClips = cell.clipsToBounds;
    [gFCShellZeroed addObject:rec];
    objc_setAssociatedObject(cell, &kFCZeroRec, rec, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    FCForceZeroFrame(cell);
    gFCZeroApplied++;
    FCLog(@"源头坑位外壳塌陷: %@ %.0fx%.0f", NSStringFromClass([cell class]), r.size.width, r.size.height);
}

// 每轮自愈：cell 离树、或内部源头痕迹消失（模板复用成正常卡片）→还原外壳，防误伤。
static void FCPruneBlockedCellShells(void) {
    if (!gFCShellZeroed.count) return;
    NSMutableArray *gone = [NSMutableArray array];
    for (FCFlattenRecord *rec in gFCShellZeroed) {
        UIView *cell = rec.view;
        if (!cell || !cell.superview) { [gone addObject:rec]; continue; }
        if (!FCCellStillHasBlockedTrace(cell, 0)) {
            FCRestoreZeroRecord(rec);
            [gone addObject:rec];
        }
    }
    [gFCShellZeroed removeObjectsInArray:gone];
}

// v38：专供自愈用——数 cell 子树的有效文字，但不因 cell 自身带 kFCZeroRec 而提前返回
// （FCCellLiveTextCount 首行会跳过带标记节点，轮播 cell 压0后自身带标记，用它自愈会永远数到0）。
// 子树里被压0/被拦的节点整枝跳过，只数真正可见的正常内容。
static NSUInteger FCCellSubtreeLiveText(UIView *root, int depth) {
    if (!root || depth > 10) return 0;
    NSUInteger n = 0;
    for (UIView *s in root.subviews) {
        if (objc_getAssociatedObject(s, &kFCZeroRec) || objc_getAssociatedObject(s, &kFCBlockedRoot)) continue;
        if (!s.hidden && s.alpha >= 0.05 && s.frame.size.width > 1 && s.frame.size.height > 1 &&
            FCOwnTextOf(s).length) n++;
        n += FCCellSubtreeLiveText(s, depth + 1);
    }
    return n;
}

// v38：轮播空壳 cell 判定 + 压0。
// v39 去类名闸门·纯几何判据。三次真机实证撑白块的外层容器类名一直在漂移：
//   v36/37 = AliIFDXCollectionViewCell；v38/39 = 普通 UIView / DXRootView。
// v38 把判据套在 AliIFDXCollectionViewCell 类名闸门后 → 这次一个都认不到（浮标压3全是老逻辑）。
// 本次诊断三层白块同页并存，全部满宽、有效文字0：
//   0,143 430x86（轮播位 UIView + DXRootView tpl:slider_icons）
//   0,236 430x155（gongge 外壳 UIView，内部 DXRootView 已被源头压0带 kFCZeroRec，"文3"是压0节点的假文字）
//   0,400 430x135（88_campaign 外壳 UIView，同上）
// 关键：FCCellLiveTextCount 遇 kFCZeroRec/kFCBlockedRoot 整枝跳过 → 上述外壳有效文字数成0，命中；
//       秒杀卡片(高155但文4~5真实可见) / 商品流(有正常文字) / 有内容卡片都因文字>1被挡。
// 判据（全满足才压）：满宽≥75%屏 / 高60~170（覆盖86/135/155，排除>170的正常大卡）
//   / 屏幕y100~450（搜索栏下运营区，排除y<100导航与y>450商品流/tabbar）
//   / 有效可见文字≤1 / 非系统容器 / 非已知商品流类。
static void FCZeroRotorCellIfEmpty(UIView *cell) {
    if (!cell || !cell.superview) return;
    if (cell.tag == 9527 || cell.tag == 9528) return;              // 插件自己的浮标/诊断窗
    // 已被别的压0逻辑认领（用户规则/v37源头外壳）——不重复处理，避免自愈互相打架
    if (objc_getAssociatedObject(cell, &kFCZeroRec)) return;
    // 系统容器与已知商品流类排除——白块外壳永远是满宽的普通 UIView/DXRootView/业务 cell，
    // 绝不能碰 UIScrollView 本体、tabbar、系统私有类、列表根容器（防整页空白/黑屏）。
    NSString *vcls = NSStringFromClass([cell class]);
    if ([cell isKindOfClass:[UIScrollView class]]) return;          // 含 UITableView/CollectionView 本体
    if ([cell isKindOfClass:[UITabBar class]] || [cell isKindOfClass:[UINavigationBar class]] ||
        [cell isKindOfClass:[UIToolbar class]]) return;
    if ([vcls hasPrefix:@"UI"] || [vcls hasPrefix:@"_UI"]) return; // 系统/私有类
    if (!gFRotorZeroed) gFRotorZeroed = [NSMutableArray array];
    for (FCFlattenRecord *rec in gFRotorZeroed) if (rec.view == cell) return;  // 幂等
    CGRect r = [cell convertRect:cell.bounds toView:nil];
    CGFloat sw = [UIScreen mainScreen].bounds.size.width;
    if (r.size.width < sw * 0.75) return;
    if (r.size.height < 60 || r.size.height > 170) return;
    if (r.origin.y < 100 || r.origin.y > 450) return;
    // 空壳判定：有效可见文字≤1。被压0/被拦的节点整枝不算——gongge/88 外壳里那 3 条文字
    // 全在被 kFCZeroRec 压0的内部 DXRootView 里，会被跳过 → 数成0 → 正确认领；
    // 秒杀卡片/商品卡片是真实可见文字 → >1 → 放行，绝不误伤。
    if (FCCellLiveTextCount(cell, 0) > 1) return;
    FCFlattenRecord *rec = [FCFlattenRecord new];
    rec.view = cell; rec.superview = cell.superview;
    rec.index = [cell.superview.subviews indexOfObject:cell];
    rec.rule = @"几何空壳";
    rec.zeroCollapsed = YES;
    rec.originalFrame = cell.frame;
    rec.originalAlpha = cell.alpha;
    rec.originalClips = cell.clipsToBounds;
    [gFRotorZeroed addObject:rec];
    objc_setAssociatedObject(cell, &kFCZeroRec, rec, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    FCForceZeroFrame(cell);
    gFCZeroApplied++;
    FCLog(@"几何空壳塌陷: %@ %.0fx%.0f @y%.0f", vcls, r.size.width, r.size.height, r.origin.y);
}

// v38：轮播空壳自愈——与 v37 口径刻意分开。
// v37 判「源头痕迹消失才还原」，但轮播位从无源头痕迹，套用会刚压就还原。
// v38 判据：cell 离树 → 移除；cell 内部冒出 >1 条有效文字（模板复用成正常卡片/秒杀位）
//   → 还原尺寸。这样白位压住、正常卡片恢复，两边都不误伤。
static void FCPruneRotorCells(void) {
    if (!gFRotorZeroed.count) return;
    NSMutableArray *gone = [NSMutableArray array];
    for (FCFlattenRecord *rec in gFRotorZeroed) {
        UIView *cell = rec.view;
        if (!cell || !cell.superview) { [gone addObject:rec]; continue; }
        // cell 自身带 kFCZeroRec，必须用专计数子树的 helper（FCCellLiveTextCount 会被自身标记挡成0）
        if (FCCellSubtreeLiveText(cell, 0) > 1) {
            FCRestoreZeroRecord(rec);
            [gone addObject:rec];
        }
    }
    [gFRotorZeroed removeObjectsInArray:gone];
}

static void FCPickNative(UIView *hit, CGPoint screenP, NSString *fallbackHint) {
    if (!hit) { FCShowBadgeMsg(@"未命中元素"); return; }
    // v21：跳过系统输入控件——真机点搜索框会命中 UIInputSetContainerView 等键盘私有类，
    // 隐藏/记规则都无意义（老大截图「已选中:UIInputSetContainerView / 原生·已记0类」）。
    NSString *hitCls = NSStringFromClass([hit class]);
    // v25：输入拦截再收紧——真机点「领券中心」券仍报「这是输入控件」，根因是阿里 DX 的
    // DXTextView 内部可能继承 UITextField 渲染文字，isKindOfClass 把它们误判成输入框。
    // 改为：只有类名「精确等于」系统 UITextField/UITextView 或含点号的系统输入私有类才算
    // 输入控件；宿主自定义子类（DX* / 点号模块名）一律当业务 view，允许点选。
    // v31：只拦「键盘/输入容器」私有类，放行普通 UITextField/UITextView——
    // 真机证据：淘宝运营条（3张177元消费券/领券中心）里的按钮与文字正是系统 UITextField/
    // UITextView 渲染的，v21~v30 精确拦它们导致老大点广告一直报「这是输入控件」选不中。
    // 键盘容器不会是广告内容，仍拦；普通输入控件在点选模式下当普通业务 view 处理。
    BOOL keyboardChrome = [hitCls hasPrefix:@"UIInputSet"] || [hitCls hasPrefix:@"_UIInputSet"] ||
                          [hitCls hasPrefix:@"UIKeyboard"] || [hitCls hasPrefix:@"_UIKeyboard"] ||
                          [hitCls rangeOfString:@"Keyboard"].location != NSNotFound;
    if (keyboardChrome) {
        FCShowBadgeMsg([NSString stringWithFormat:@"是键盘容器(%@),请点广告内容区", hitCls]);
        return;
    }
    UIView *card = FCCardContainerFrom(hit);
    // v45：点在表格行里 → 直接对整行操作。真机证据（v44 诊断 + 截图）：我的淘宝每个板块
    // 就是一个 MTDinamicXCell（0,501 430x142），只隐藏内层内容时行高 142pt 还占着 = 一片白，
    // 老大看到的就是「点不掉 / 点掉了变白块」。隐藏整行 + 行高归零才是真「去掉」。
    BOOL escalatedToRow = NO;
    {
        UITableViewCell *rowCell = FCEnclosingRowCell(card);
        if (rowCell) {
            CGRect rr = [rowCell convertRect:rowCell.bounds toView:nil];
            CGFloat shh = [UIScreen mainScreen].bounds.size.height;
            if (rr.size.height <= shh * 0.45 && FCCellLiveTextCount(rowCell, 0) <= 12) {
                card = rowCell;
                escalatedToRow = YES;
                FCLog(@"点选升级到整行：%@ %.0fx%.0f @y%.0f",
                      NSStringFromClass([rowCell class]), rr.size.width, rr.size.height, rr.origin.y);
            }
        }
    }
    NSString *ruleText = FCPickRuleText(card);
    CGRect markRect = [card convertRect:card.bounds toView:nil];
    NSString *cls = NSStringFromClass([hit class]);
    // v25：红框标签带上命中类名——老大反馈「部分元素无法选取」，截图带类名才能一次
    // 定位到底命中了什么（是 DXTextView 还是空壳 WK 还是别的），不再靠猜。
    NSString *engTag2 = FCEngineName(FCEngineOfClass(cls));
    // v29：取该元素所属 DX 模板名——红框显示，截图一次即可确认点中了哪个卡片模板
    NSString *tplName = FCTemplateNameOfView(hit);
    NSString *show = tplName.length
        ? [NSString stringWithFormat:@"%@·模板:%@", engTag2, tplName]
        : [NSString stringWithFormat:@"%@·%@", engTag2, ruleText.length ? ruleText : cls];
    FCShowPickMark(markRect, show);
    // v19：若降级来自网页通道（触点本在 H5 内），card/hit 多半在 webview 内部——
    // 隐藏它=隐藏整个网页、存 pos=全屏误伤规则。此时只记诊断，不隐藏、不存位置。
    BOOL fromWeb = [fallbackHint rangeOfString:@"网页"].location != NSNotFound;
    // v24：引擎判定——只有命中元素「自身引擎是 H5」才视为真 H5 内容、禁止降级隐藏。
    // v23 及之前用「祖先链有 WK」判断，被空壳 WKWebView 带偏：hit 已被 FCHitViewAtPoint
    // 穿透换成 DX view（引擎非 H5），但祖先链仍可能挂空壳 WK → 误拦死。改为看命中元素引擎。
    FCEngine hitEngine = FCEngineOfView(hit);
    BOOL trulyH5 = (hitEngine == FCEngineH5);
    // v44：真机「超级88领券中心」始终去不掉的根因就在这里——引擎把它判成 H5，
    // 旧逻辑直接 return，结果一条规则都没存，用户点多少次都白点。
    // 改为：真 H5 内容仍然不隐藏（隐藏=藏整个网页），但 cls:/pos: 指纹照存，
    // 由扫描阶段的几何匹配去认领它，不依赖引擎判定。
    BOOL h5Only = (fromWeb && trulyH5);
    if (h5Only) {
        FCLog(@"点选降级：引擎判 H5，只记指纹不隐藏（%@ %.0fx%.0f @y%.0f）",
              NSStringFromClass([card class]), markRect.size.width, markRect.size.height,
              markRect.origin.y);
    } else {
        card.hidden = YES;
        if (!gFCPickHidden) gFCPickHidden = [NSHashTable weakObjectsHashTable];
        [gFCPickHidden addObject:card];
        FCMarkRowZero(card);   // v45：压的是表格行就把行高也归零，否则留下等高的白
        gFCNativeHits++;
        // v46：升级到整行时**不存文字规则**。真机 v45 证据：点了「领券中心」这一行，
        // 存下的却是行内某个券卡的文案（规则6/8「¥100有价优惠券 / ¥120有价优惠券」），
        // 扫描时只压中那张券（99x103），留下一块 103pt 白，整行还在。
        // 整行只靠 pos: 规则认领（下面会存 0.000,0.537,1.000,0.153 这种整行矩形）。
        if (ruleText.length >= 2 && !escalatedToRow) FCAddUserRule(ruleText);
        // v29：DX 动态化卡片存模板规则——Deep 档源头 setData: 按此拦截，根治「删了被重绘」
        if (tplName.length) FCAddUserRule([@"tpl:" stringByAppendingString:tplName]);
    }
    // v18：跳过 webview 私有类(WKContentView 等)，从卡片往上找真正的宿主自定义类
    NSUInteger clsAdded = 0;
    UIView *curC = card;
    CGFloat fullW = [UIScreen mainScreen].bounds.size.width;
    CGFloat fullH = [UIScreen mainScreen].bounds.size.height;
    for (int depth = 0; curC && depth < 8; depth++) {
        NSString *c = NSStringFromClass([curC class]);
        // 排除 webview 及其私有类——否则存下 cls:WKContentView 这类无效规则
        BOOL webPriv = ([c rangeOfString:@"WK"].location == 0) ||
                       ([c rangeOfString:@"Web"].location != NSNotFound && [c hasPrefix:@"_"]);
        BOOL hostClass = ([c rangeOfString:@"."].location != NSNotFound) ||
            (![c hasPrefix:@"UI"] && ![c hasPrefix:@"NS"] && ![c isEqualToString:@"UIView"]);
        // v24：不存占屏≥90% 的容器类名——那基本是页面根容器(DXRootView 等)，
        // 存下来命中即整页消失。真机「领券中心」这类卡片远小于全屏，照常存。
        CGRect cr = [curC convertRect:curC.bounds toView:nil];
        BOOL tooBig = cr.size.width >= fullW * 0.90 && cr.size.height >= fullH * 0.90;
        if (hostClass && !webPriv && !tooBig && c.length >= 6 && !FCIsUnsafeClassRule(c)) {
            FCAddUserRule([@"cls:" stringByAppendingString:c]);
            clsAdded++;
        }
        curC = curC.superview;
    }
    CGSize scr = [UIScreen mainScreen].bounds.size;
    CGRect nr = [card convertRect:card.bounds toView:nil];
    // v44：门槛与 FCIsUnsafeClassRule 对齐——旧条件要求「宽和高都 <90%屏」，
    // 而淘宝运营位几乎都满宽（430/430=100%），于是所有满宽卡片都存不了 pos 规则，
    // 点选永远无效（真机「超级88领券中心」430x142 就是这个死法）。
    // 根容器的特征是「宽 ≥90% 屏 **且** 高 ≥90% 屏」同时成立，只满足一个是正常卡片。
    if (nr.size.width >= 40 && nr.size.height >= 18 &&
        !(nr.size.width >= scr.width * 0.90 && nr.size.height >= scr.height * 0.90)) {
        FCAddUserRule([NSString stringWithFormat:@"pos:%.3f,%.3f,%.3f,%.3f",
            nr.origin.x/scr.width, nr.origin.y/scr.height,
            nr.size.width/scr.width, nr.size.height/scr.height]);
    }
    NSString *prefix = fallbackHint.length ? fallbackHint : @"";
    // v20：网页降级提示(含"网页"/"H5")保持原样；引擎提示(如"DX动态·")不再重复"原生"二字
    BOOL enginePrefix = [prefix rangeOfString:@"网页"].location == NSNotFound &&
                        [prefix rangeOfString:@"H5"].location == NSNotFound && prefix.length > 0;
    NSString *msg;
    if (h5Only) {
        // v44：明确告知「已记住」而不是「失败」——之前提示失败，用户以为没生效反复点
        msg = [NSString stringWithFormat:@"判定H5·已记%lu类+位置(不回退隐藏)",
               (unsigned long)clsAdded];
    } else {
        msg = enginePrefix
            ? [NSString stringWithFormat:@"%@已记%lu类+位置", prefix, (unsigned long)clsAdded]
            : [NSString stringWithFormat:@"%@原生·已记%lu类+位置", prefix, (unsigned long)clsAdded];
    }
    // v29：把模板名带进浮标提示——老大截图即可确认源头拦截规则已存
    if (tplName.length) msg = [NSString stringWithFormat:@"%@|模板已记", msg];
    FCShowBadgeMsg(msg);
}

static void FCPickAtPoint(CGPoint screenP) {
    Class wk = NSClassFromString(@"WKWebView");
    UIView *hit = FCHitViewAtPoint(screenP);
    if (!hit) { FCShowBadgeMsg(@"未命中元素"); return; }
    // v20：先识别触点板块的渲染引擎——这是判定走网页还是原生的根本依据。
    // 真机实证：淘宝「超级88领券中心」是 DXRootView（DX 原生动态化），而页面里
    // frame 0,0 满屏的 WKWebView DOM 为空（空壳容器），旧逻辑按祖先链见 webview
    // 就走网页，被空壳带偏。改为：引擎非 H5 → 直接原生通道。
    FCEngine eng = FCEngineOfView(hit);
    NSString *engTag = FCEngineName(eng);
    UIView *cur = hit, *web = nil;
    while (cur) {
        if (wk && [cur isKindOfClass:wk]) { web = cur; break; }
        cur = cur.superview;
    }
    // v20：只有「引擎判为 H5」且 web 可见够大覆盖触点，才走网页通道；
    // DX/RN/Flutter/原生引擎一律走原生（哪怕祖先链挂着空壳 webview）。
    CGRect webFrame = web ? [web convertRect:web.bounds toView:nil] : CGRectZero;
    BOOL webVisible = web && !web.hidden && web.alpha >= 0.05 &&
                      webFrame.size.width >= 160 && webFrame.size.height >= 160 &&
                      CGRectContainsPoint(webFrame, screenP);
    BOOL webReal = (eng == FCEngineH5) && webVisible;
    FCLog(@"点选引擎=%@ web实体=%d 命中类=%@", engTag, webReal, NSStringFromClass([hit class]));
    if (webReal) {
        SEL sel = NSSelectorFromString(@"evaluateJavaScript:completionHandler:");
        if (![web respondsToSelector:sel]) {
            FCPickNative(hit, screenP, @"网页不可用→"); return;  // v18：降级
        }
        IMP imp = [web methodForSelector:sel]; if (!imp) {
            FCPickNative(hit, screenP, @"网页不可用→"); return;  // v18：降级
        }
        CGPoint lp = [web convertPoint:screenP fromView:nil];
        NSString *js = [NSString stringWithFormat:FCPickJSFmt, lp.x, lp.y];
        UIView *capturedHit = hit;  // v18：block 里降级要用到触点 view
        ((void (*)(id, SEL, NSString *, void (^)(id, NSError *)))imp)
            (web, sel, js, ^(id result, NSError *err){
                NSString *txt0 = ([result isKindOfClass:[NSString class]]) ? (NSString *)result : @"";
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
                            CGRect wf = [web convertRect:web.bounds toView:nil];
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
                        if (added) {
                            dispatch_async(dispatch_get_main_queue(), ^{
                                FCInjectWebViews(NO);
                                FCShowBadgeMsg(added ? @"网页·已隐藏并记住" : @"网页·已隐藏");
                            });
                            return;
                        }
                        // v18：JS 命中元素但没提取到任何有效特征 → 也降级原生
                        dispatch_async(dispatch_get_main_queue(), ^{
                            FCPickNative(capturedHit, screenP, @"网页无特征→");
                        });
                        return;
                    }
                }
                // v19：把 JS 具体返回码透传到浮标，截图一次即可定位失败类型
                NSString *why = @"网页未中→";
                if (err) {
                    why = @"网页报错→";
                } else if ([txt0 isEqualToString:@"TOOBIG"]) {
                    why = @"网页过大→";
                } else if ([txt0 hasPrefix:@"MISS"]) {
                    why = @"网页空点→";
                }
                // v18：网页 MISS/TOOBIG/err → 自动降级到原生拾取（核心修复）
                NSString *hint = why;
                dispatch_async(dispatch_get_main_queue(), ^{
                    FCPickNative(capturedHit, screenP, hint);
                });
            });
    } else {
        // v20：DX/RN/原生引擎 → 原生拾取，浮标前缀显示识别到的板块引擎类型
        FCPickNative(hit, screenP, [NSString stringWithFormat:@"%@·", engTag]);
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
    if ([r hasPrefix:@"tpl:"]) return @"模";   // v29：DX 模板指纹
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
    if ([r hasPrefix:@"tpl:"]) return [UIColor colorWithRed:0.95 green:0.30 blue:0.20 alpha:1];  // v29：模板=红橙
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
- (void)fcCopyDiag;    // v20：复制全文
- (void)fcCopyBrief;   // v21：复制精简要点（可直接发）
- (void)fcShowCopied:(NSString *)t;
@end
static FCDiagWindow *gFCDiagWindow = nil;
static UITextView *gFCDiagText = nil;
static UILabel *gFCDiagToast = nil;

// v21：从诊断全文提炼精简要点——老大反馈日志几千字发不出去。
// 保留：标题/顶层VC/引擎图例/有广告类型或命中的行/WKWebView摘要；其余细节丢弃。
static NSString *FCDiagBriefString(void) {
    NSString *full = gFCDiagText.text ?: @"";
    NSMutableString *brief = [NSMutableString string];
    NSUInteger kept = 0;
    // v27：DX 源头取证是定位淘宝运营位的唯一新证据，先无条件收进精简版，
    // 避免被前面大段日志（如 40 条网络请求）挤到行数上限之外。
    for (NSString *line in [full componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:@"----- DX 动态化源头取证"] ||
            [line hasPrefix:@"[DX类表]"] || [line hasPrefix:@"[DX类]"] ||
            [line hasPrefix:@"[DX方法]"] ||
            [line hasPrefix:@"----- 源头参数取证"] || [line hasPrefix:@"[取证]"] ||
            [line hasPrefix:@"[DXRootView.setData]"] || [line hasPrefix:@"[DXRootView.setTemplateItem]"] ||
            [line hasPrefix:@"[DXScrollerLayoutCell.setViewModel]"]) {
            [brief appendFormat:@"%@\n", line];
            kept++;
        }
    }
    // 每种引擎保留少量代表行，让用户从精简版也能看清页面由哪些板块技术构成
    NSMutableDictionary<NSString *, NSNumber *> *engineQuota = [NSMutableDictionary dictionary];
    const NSUInteger kPerEngine = 3;
    for (NSString *line in [full componentsSeparatedByString:@"\n"]) {
        // v27：DX 行已在开头收录，主循环跳过避免重复占用行数
        if ([line hasPrefix:@"----- DX 动态化源头取证"] ||
            [line hasPrefix:@"[DX类表]"] || [line hasPrefix:@"[DX类]"] ||
            [line hasPrefix:@"[DX方法]"] ||
            [line hasPrefix:@"----- 源头参数取证"] || [line hasPrefix:@"[取证]"] ||
            [line hasPrefix:@"[DXRootView.setData]"] || [line hasPrefix:@"[DXRootView.setTemplateItem]"] ||
            [line hasPrefix:@"[DXScrollerLayoutCell.setViewModel]"]) continue;
        BOOL keep = NO;
        if ([line hasPrefix:@"====="] || [line hasPrefix:@"顶层VC"] ||
            [line hasPrefix:@"用户规则"] || [line hasPrefix:@"  规则"] ||
            [line hasPrefix:@"[引擎图例]"] || [line hasPrefix:@"[提示]"] ||
            [line hasPrefix:@"----- WKWebView"] || [line hasPrefix:@"[网页]"] ||
            [line hasPrefix:@"----- 网络取证"] || [line hasPrefix:@"[请求]"] ||
            [line hasPrefix:@"[已截断]"]) keep = YES;
        if ([line rangeOfString:@"[类型:"].location != NSNotFound) keep = YES;  // 命中广告类的行
        if ([line rangeOfString:@"命中:无"].location == NSNotFound &&
            [line rangeOfString:@"命中:"].location != NSNotFound) keep = YES;     // 命中用户规则的行
        // v21：未命中的板块行也按引擎各留几条，回答「点不中的到底是什么板块」
        if (!keep && [line hasPrefix:@"["]) {
            NSRange rb = [line rangeOfString:@"]"];
            if (rb.location != NSNotFound) {
                NSString *eng = [line substringWithRange:NSMakeRange(1, rb.location - 1)];
                NSUInteger used = [engineQuota[eng] unsignedIntegerValue];
                if (used < kPerEngine) { engineQuota[eng] = @(used + 1); keep = YES; }
            }
        }
        if (keep) {
            [brief appendFormat:@"%@\n", line];
            if (++kept >= 70) { [brief appendString:@"[精简已达70行上限]\n"]; break; }
        }
    }
    return brief.length ? brief : full;
}

@implementation FCDiagWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (void)fcCloseDiag {
    [self.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    self.hidden = YES;
    gFCDiagText = nil;
    gFCDiagToast = nil;
}
- (void)fcCopyDiag {   // v20：复制全文
    NSString *t = gFCDiagText.text ?: @"";
    if (t.length) [self fcShowCopied:t];
}
- (void)fcCopyBrief {  // v21：复制精简要点
    NSString *t = FCDiagBriefString();
    if (t.length) [self fcShowCopied:t];
}
- (void)fcShowCopied:(NSString *)t {
    [UIPasteboard generalPasteboard].string = t;
    if (gFCDiagToast) {
        gFCDiagToast.text = [NSString stringWithFormat:@"已复制 %lu 字，可直接粘贴发我",
                             (unsigned long)t.length];
        gFCDiagToast.hidden = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ gFCDiagToast.hidden = YES; });
    }
}
@end

static void FCAppendDiagText(NSString *s) {
    if (!gFCDiagText) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        gFCDiagText.text = [gFCDiagText.text stringByAppendingFormat:@"%@\n", s];
        [gFCDiagText scrollRangeToVisible:NSMakeRange(gFCDiagText.text.length, 0)];
    });
}

// v22：规则类型标注——让用户看清存的到底是文字还是指纹，一眼定位点选存了什么
static NSString *FCDiagRuleKind(NSString *rule) {
    if ([rule hasPrefix:@"cls:"]) return @"类名";
    if ([rule hasPrefix:@"pos:"]) return @"位置";
    if ([rule hasPrefix:@"sel:"]) return @"选择器";
    if ([rule hasPrefix:@"img:"]) return @"图片";
    if ([rule hasPrefix:@"tpl:"]) return @"模板";   // v29
    if ([rule hasPrefix:@"#"] || [rule hasPrefix:@"."]) return @"CSS";
    return @"文字";
}

// v22：诊断命中判定——完整复刻 FCApplyNativeRules 的真实顺序（类名精确 → cls:/pos: 指纹
// → 整棵子树文字）。v21 只看自身文字，导致「隐藏已命中却显示命中:无」的误导，诊断必须
// 和执行隐藏同口径才有排障价值。
static NSString *FCDiagHitRule(UIView *v, NSArray<NSString *> *rules) {
    NSString *vcls = NSStringFromClass([v class]);
    CGRect r = [v convertRect:v.bounds toView:nil];
    CGFloat sw = [UIScreen mainScreen].bounds.size.width;
    CGFloat sh = [UIScreen mainScreen].bounds.size.height;
    for (NSString *rule in rules) {
        if (rule.length >= 5 && [rule isEqualToString:vcls]) return rule;              // 类名精确
        if (FCRuleMatchesFingerprint(rule, vcls, r, sw, sh)) return rule;                // cls:/pos:
    }
    NSArray *texts = FCTextsOf(v);                                                       // 整棵子树文字
    for (NSString *s in texts)
        for (NSString *rule in rules)
            if (FCRuleMatchesText(rule, s)) return rule;
    return nil;
}

// v22：取宿主顶层 VC——FCDiagWindow 自己可以成为 keyWindow，导致 FCTopViewController 拿到
// 插件窗（无 rootVC）显示「顶层VC:-」。遍历所有非插件 window，找第一个有 rootVC 的。
static UIViewController *FCHostTopVC(void) {
    for (UIWindow *w in FCAllWindows()) {
        NSString *wc = NSStringFromClass([w class]);
        if ([wc isEqualToString:@"FCBadgeWindow"] || [wc isEqualToString:@"FCPanelWindow"] ||
            [wc isEqualToString:@"FCDiagWindow"]) continue;
        UIViewController *vc = w.rootViewController;
        if (!vc) continue;
        int guard = 0;
        while (vc.presentedViewController && guard++ < 12) vc = vc.presentedViewController;
        return vc;
    }
    return nil;
}

// v27：DX 动态化源头取证（纯只读，不 hook、不改任何运行时行为）。
// 淘宝运营位诊断「命中✓仍可见」= DX 引擎重绘恢复，Pure 视图层删除已到天花板；静态二进制
// 看不到 Swift/ObjC 方法名，必须运行时取证才能定位源头拦截点，不能继续猜容器层级。
static void FCAppendDXMethodProbe(void) {
    // ①扫全部已注册类，反推真机上 DX/动态化的真实类名（从证据反推前缀，不猜）
    unsigned int nc = 0;
    Class *all = objc_copyClassList(&nc);
    NSMutableArray<NSString *> *dxClasses = [NSMutableArray array];
    if (all) {
        for (unsigned int i = 0; i < nc; i++) {
            const char *raw = class_getName(all[i]);
            if (!raw) continue;
            NSString *cn = [NSString stringWithUTF8String:raw];
            if (cn.length < 2) continue;
            if ([cn hasPrefix:@"DX"] || [cn rangeOfString:@"TurboUI"].location != NSNotFound ||
                [cn rangeOfString:@"Weex"].location != NSNotFound) {
                if (![dxClasses containsObject:cn] && dxClasses.count < 40) [dxClasses addObject:cn];
            }
        }
        free(all);                                  // objc_copyClassList 返回 malloc 数组必须 free
    }
    FCAppendDiagText([NSString stringWithFormat:@"[DX类表] 扫到 %lu 个 DX/动态化类:",
                      (unsigned long)dxClasses.count]);
    for (NSUInteger i = 0; i < dxClasses.count; i += 4) {
        NSUInteger e = MIN(i + 4, dxClasses.count);
        NSMutableArray *chunk = [NSMutableArray array];
        for (NSUInteger j = i; j < e; j++) [chunk addObject:dxClasses[j]];
        FCAppendDiagText([@"[DX类] " stringByAppendingString:[chunk componentsJoinedByString:@","]]);
    }

    // ②关键类方法清单：自身 + 两层父类 selector，定位 data/bind/render 源头入口
    NSArray<NSString *> *keys = @[
        @"DXRootView", @"DXRootViewWrapperView", @"DXBaseDataParser",
        @"DXImageView", @"DXTextView", @"DXScrollerLayoutCell",
        @"DXCardModel", @"_TtC23TurboUIBuilderFramework11DXCardModel"
    ];
    for (NSString *name in keys) {
        Class c = NSClassFromString(name);
        if (!c) {
            FCAppendDiagText([NSString stringWithFormat:@"[DX方法] %@: 类不存在", name]);
            continue;
        }
        NSMutableArray<NSString *> *sels = [NSMutableArray array];
        Class cur = c;
        int depth = 0;
        while (cur && depth++ < 3 && sels.count < 45) {
            unsigned int n = 0;
            Method *list = class_copyMethodList(cur, &n);
            for (unsigned int i = 0; i < n && sels.count < 45; i++) {
                NSString *sn = NSStringFromSelector(method_getName(list[i]));
                if (!sn.length) continue;
                [sels addObject:([cur isEqual:c] ? sn : [sn stringByAppendingString:@"(父)"])];
            }
            if (list) free(list);                   // class_copyMethodList 的 Method* 也要 free
            cur = class_getSuperclass(cur);
        }
        FCAppendDiagText([NSString stringWithFormat:@"[DX方法] %@(%lu): %@",
            name, (unsigned long)sels.count, [sels componentsJoinedByString:@","]]);
    }
}

// v28：源头参数取证日志——Deep 档 hook 写入、诊断面板读取，提前定义避免前向引用
#ifdef FC_DEEP_HOOKS
static NSMutableArray<NSString *> *gFCProbeLog = nil;
static NSMutableArray<NSString *> *gFCProbeHits = nil;
static NSMutableArray<NSString *> *gFCProbeDeep = nil;   // v31：secondfloor 深层文案路径取证
static NSUInteger gFCProbeDropped = 0;
#endif

// v35：统计子树有效文字条数（上限3即止，供白块候选判定；浅层即可，深容器不必全扫）
static NSUInteger FCCountSubTexts(UIView *v, int depth) {
    if (!v || depth > 8) return 0;
    NSUInteger n = FCOwnTextOf(v).length ? 1 : 0;
    if (n >= 3) return n;
    for (UIView *s in v.subviews) {
        n += FCCountSubTexts(s, depth + 1);
        if (n >= 3) break;
    }
    return n;
}

// v36：兜底只读诊断——列出「看起来在撑高度的大容器」。
// v36 三处修正（v35 真机误报「无」、但截图白块明摆着的根因）：
//   ① UIScrollView/UICollectionView/UITableView 不再直接排除，只报告类名由人判断（撑高度常是它们）
//   ② 子树有效文字阈值 2 → 8（白块右侧挂着秒杀卡片多文字，v35 被这条全挡掉）
//   ③ 已压0容器也列出并标 originalFrame（v35 直接跳过，看不到被 DX 重设 frame 的容器）
static void FCAppendBlankContainerDiag(void) {
    CGFloat sw = [UIScreen mainScreen].bounds.size.width;
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    // v36：只排除真正的系统 chrome 与叶子控件；滚动/列表容器保留为候选
    NSArray *hardExclude = @[@"UIWindow", @"UITabBar", @"UINavigationBar", @"UIToolbar",
                             @"UILabel", @"UIImageView", @"UIButton", @"WKWebView",
                             @"UISwitch", @"UISlider"];
    for (UIWindow *w in FCAllWindows()) {
        NSString *wc = NSStringFromClass([w class]);
        if ([wc isEqualToString:@"FCBadgeWindow"] || [wc isEqualToString:@"FCPanelWindow"] ||
            [wc isEqualToString:@"FCDiagWindow"]) continue;
        NSMutableArray<UIView *> *q = [NSMutableArray arrayWithObject:w];
        NSUInteger idx = 0;
        while (idx < q.count && idx < 1500 && out.count < 10) {
            UIView *v = q[idx++];
            for (UIView *sub in v.subviews) [q addObject:sub];
            NSString *cls = NSStringFromClass([v class]);
            BOOL excluded = NO;
            for (NSString *e in hardExclude) if ([cls isEqualToString:e]) { excluded = YES; break; }
            if (excluded) continue;
            CGRect r = [v convertRect:v.bounds toView:nil];
            if (r.size.width < sw * 0.75 || r.size.height < 120 || r.size.height > 700) continue;
            if (r.origin.y < 60 || r.origin.y > 780) continue;
            NSUInteger txt = FCCountSubTexts(v, 0);
            if (txt > 8) continue;                       // v36：2 → 8，放宽挂了秒杀卡片的坑位
            NSString *tpl = gFCTplBridge ? [gFCTplBridge objectForKey:v] : nil;
            BOOL blocked = tpl.length ? FCTplIsBlocked(tpl) : NO;
            FCFlattenRecord *zr = objc_getAssociatedObject(v, &kFCZeroRec);
            NSString *orig = zr ? [NSString stringWithFormat:@" 原%.0fx%.0f",
                                   zr.originalFrame.size.width, zr.originalFrame.size.height] : @"";
            [out addObject:[NSString stringWithFormat:
                @"[白块候选] %@ | %.0f,%.0f %.0fx%.0f | 子%lu 文%lu | 压:%@%@ | tpl:%@ 拦:%@",
                cls, r.origin.x, r.origin.y, r.size.width, r.size.height,
                (unsigned long)v.subviews.count, (unsigned long)txt,
                zr ? @"是" : @"否", orig, tpl.length ? tpl : @"-", blocked ? @"是" : @"否"]];
        }
    }
    if (!out.count) FCAppendDiagText(@"[白块候选] 无（放宽判据后仍未发现大容器）");
    else FCAppendDiagText(@"[白块候选] 放宽判据后候选:");
    for (NSString *line in out) FCAppendDiagText(line);
}

// v36：坐标反查——白块区采样点（首页推荐tab，屏幕 y≈140~550）覆盖的所有大容器。
// 按面积从小到大排：最小的最可能是真正撑高度的内容容器，最大的是页面根容器。
// 这是「诊断要覆盖问题对象本身不可见」的落地：白块=无文字大容器，按坐标抓比按文字抓可靠。
static void FCAppendCoordinateProbe(void) {
    CGFloat sw = [UIScreen mainScreen].bounds.size.width;
    NSArray *pts = @[[NSValue valueWithCGPoint:CGPointMake(sw * 0.5, 200)],
                     [NSValue valueWithCGPoint:CGPointMake(sw * 0.5, 350)],
                     [NSValue valueWithCGPoint:CGPointMake(sw * 0.5, 500)]];
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    for (UIWindow *w in FCAllWindows()) {
        NSString *wc = NSStringFromClass([w class]);
        if ([wc isEqualToString:@"FCBadgeWindow"] || [wc isEqualToString:@"FCPanelWindow"] ||
            [wc isEqualToString:@"FCDiagWindow"]) continue;
        NSMutableArray<UIView *> *q = [NSMutableArray arrayWithObject:w];
        NSUInteger idx = 0;
        while (idx < q.count && idx < 1500) {
            UIView *v = q[idx++];
            for (UIView *sub in v.subviews) [q addObject:sub];
            CGRect r = [v convertRect:v.bounds toView:nil];
            if (r.size.width < sw * 0.5 || r.size.height < 80) continue;
            BOOL cover = NO;
            for (NSValue *nv in pts) if (CGRectContainsPoint(r, nv.CGPointValue)) { cover = YES; break; }
            if (!cover) continue;
            NSString *cls = NSStringFromClass([v class]);
            NSString *tpl = gFCTplBridge ? [gFCTplBridge objectForKey:v] : nil;
            BOOL zeroed = objc_getAssociatedObject(v, &kFCZeroRec) != nil;
            NSString *line = [NSString stringWithFormat:
                @"[坐标] %@ | %.0f,%.0f %.0fx%.0f | 压:%@ a%.2f | 子%lu | tpl:%@",
                cls, r.origin.x, r.origin.y, r.size.width, r.size.height,
                zeroed ? @"是" : @"否", v.alpha, (unsigned long)v.subviews.count,
                tpl.length ? tpl : @"-"];
            [items addObject:@{@"area": @(r.size.width * r.size.height), @"line": line}];
        }
    }
    if (!items.count) {
        FCAppendDiagText(@"[坐标反查] 采样点无覆盖容器");
        return;
    }
    [items sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"area"] compare:b[@"area"]];
    }];
    FCAppendDiagText([NSString stringWithFormat:
        @"[坐标反查] 白块采样点(x中心,y=200/350/500)覆盖大容器 %lu 个(按面积小→大):",
        (unsigned long)items.count]);
    NSUInteger lim = items.count > 14 ? 14 : items.count;
    for (NSUInteger i = 0; i < lim; i++) FCAppendDiagText(items[i][@"line"]);
}

// v36：已压0容器清单——列出所有高度≥100的压0记录，含原始frame与当前frame。
// 专抓「压0后 DX 又重设 frame 回来」：originalFrame 是白块区域、当前 frame 却恢复成大尺寸，
// 就说明每轮重压没压住那层，白块正是它撑的。
static void FCAppendZeroedList(void) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (FCFlattenRecord *rec in gFCFlattened) {
        if (!rec.zeroCollapsed) continue;
        CGRect orig = rec.originalFrame;
        if (orig.size.height < 100) continue;
        UIView *v = rec.view;
        CGRect now = v ? [v convertRect:v.bounds toView:nil] : CGRectZero;
        // v43：加「留白」——该记录原来占多少高度，就是压了以后留下多少空白
        [out addObject:[NSString stringWithFormat:
            @"[压0清单] %@ | 原%.0f,%.0f %.0fx%.0f → 今 %.0fx%.0f a%.2f | 留白%.0fpt 父=%@ | %@",
            NSStringFromClass([v class]), orig.origin.x, orig.origin.y,
            orig.size.width, orig.size.height, now.size.width, now.size.height,
            v ? v.alpha : -1, orig.size.height,
            v.superview ? NSStringFromClass([v.superview class]) : @"-",
            rec.rule.length ? rec.rule : @"-"]];
    }
    for (FCFlattenRecord *rec in (gFCSourceZeroed ?: @[])) {
        CGRect orig = rec.originalFrame;
        if (orig.size.height < 100) continue;
        UIView *v = rec.view;
        CGRect now = v ? [v convertRect:v.bounds toView:nil] : CGRectZero;
        [out addObject:[NSString stringWithFormat:
            @"[压0清单·源] %@ | 原%.0f,%.0f %.0fx%.0f → 今 %.0fx%.0f a%.2f | 留白%.0fpt 父=%@ | %@",
            NSStringFromClass([v class]), orig.origin.x, orig.origin.y,
            orig.size.width, orig.size.height, now.size.width, now.size.height,
            v ? v.alpha : -1, orig.size.height,
            v.superview ? NSStringFromClass([v.superview class]) : @"-",
            rec.rule.length ? rec.rule : @"-"]];
    }
    // v43：留白合计——直接回答「现在页面空了多少」
    {
        CGFloat wh = FCWhiteSpaceEstimate();
        CGFloat sh = [UIScreen mainScreen].bounds.size.height;
        FCAppendDiagText([NSString stringWithFormat:
            @"[留白] 合计 %.0fpt（约 %.0f%% 屏高，大块免压=%@，阈值%.0fpt）",
            wh, sh > 0 ? wh / sh * 100 : 0,
            FCBigBlockPassOn() ? @"开" : @"关", kFCBigBlockH]);
    }
    if (!out.count) FCAppendDiagText(@"[压0清单] 无高度≥100的压0记录");
    else {
        FCAppendDiagText([NSString stringWithFormat:@"[压0清单] 高度≥100的压0记录 %lu 条:",
                          (unsigned long)out.count]);
        NSUInteger lim = out.count > 12 ? 12 : out.count;
        for (NSUInteger i = 0; i < lim; i++) FCAppendDiagText(out[i]);
    }
    // v45：行高归零取证——「压了但还留白」时，看这里就知道是没登记上还是代理没接管。
#ifdef FC_DEEP_HOOKS
    {
        NSUInteger rows = 0;
        for (UITableView *tv in gFCRowMarks.keyEnumerator)
            rows += [[gFCRowMarks objectForKey:tv] count];
        if (gFCRowMarks.count) {
            FCAppendDiagText([NSString stringWithFormat:
                @"[行高归零] 已接管代理 %lu 个 / 登记表格 %lu 个 / 归零行 %lu 行",
                (unsigned long)gFCRowHookedKeys.count,
                (unsigned long)gFCRowMarks.count, (unsigned long)rows]);
        } else {
            FCAppendDiagText([NSString stringWithFormat:
                @"[行高归零] 未登记行（已接管代理 %lu 个）；目标不是 UITableViewCell 或还没点选",
                (unsigned long)gFCRowHookedKeys.count]);
        }
        if (gFCRowProbe.length)
            FCAppendDiagText([@"[行高归零·代理] " stringByAppendingString:gFCRowProbe]);
    }
#else
    FCAppendDiagText(@"[行高归零] Pure 档不支持（零 hook）");
#endif
}

// v40：高度归属诊断——白块到底是「内容撑的」还是「高度规格给的」。
// 打印每个被拦 DXRootView 的高度规格值/类型、宿主列表类名、是否已归零；
// 若全是 spec=nil 或 非NSNumber，下一版就知道该换哪个字段下手，不用再猜。
static void FCAppendHeightOwnerDiag(void) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (UIWindow *w in FCAllWindows()) {
        NSString *wc = NSStringFromClass([w class]);
        if ([wc hasPrefix:@"FC"]) continue;
        NSMutableArray<UIView *> *q = [NSMutableArray arrayWithObject:w];
        NSUInteger i = 0;
        while (i < q.count && i < 1200) {
            UIView *v = q[i++];
            for (UIView *s in v.subviews) [q addObject:s];
            if (![NSStringFromClass([v class]) isEqualToString:@"DXRootView"]) continue;
            if (!objc_getAssociatedObject(v, &kFCBlockedRoot) &&
                !objc_getAssociatedObject(v, &kFCZeroRec)) continue;
            // v41：只查「有没有 setter」，不读 originalHeightSpec 的值——
            // 上一版就是读回值把垃圾指针当对象 retain 崩掉的（objc_retain 0x3fffffff）。
            BOOL canSet = [v respondsToSelector:@selector(setOriginalHeightSpec:)];
            UIView *host = v.superview; int g = 0;
            while (host && g++ < 10 && ![host isKindOfClass:[UICollectionView class]] &&
                   ![host isKindOfClass:[UITableView class]]) host = host.superview;
            CGRect r = [v convertRect:v.bounds toView:nil];
            [out addObject:[NSString stringWithFormat:
                @"%@ | %.0fx%.0f @y%.0f | setter=%@ | 宿主=%@ | 已归零=%@",
                NSStringFromClass([v class]), r.size.width, r.size.height, r.origin.y,
                canSet ? @"有" : @"无",
                host ? NSStringFromClass([host class]) : @"无",
                objc_getAssociatedObject(v, &kFCHeightZeroed) ? @"是" : @"否"]];
        }
    }
    FCAppendDiagText([NSString stringWithFormat:
        @"[高度归零] 成功 %lu / 跳过 %lu（v41 只写不读，不再读 spec 旧值）",
        (unsigned long)gFCHeightZeroOK, (unsigned long)gFCHeightZeroSkip]);
    // v41：把 setter 的 type encoding 打出来——上版闪退就是「参数根本不是对象」，
    // v=void、@=对象、{CGSize=dd}=结构体传值。看到结构体就说明得按值再调一次。
    FCAppendDiagText([NSString stringWithFormat:@"[高度签名] setOriginalHeightSpec: %@",
                      gFCHeightSetEnc.length ? gFCHeightSetEnc : @"(未取到/未装载Deep档)"]);
    if (!out.count) { FCAppendDiagText(@"[高度归属] 当前无被拦 DXRootView（可能还没滚到运营位）"); return; }
    FCAppendDiagText([NSString stringWithFormat:@"[高度归属] 被拦 root %lu 个:", (unsigned long)out.count]);
    NSUInteger n = MIN(out.count, (NSUInteger)8);
    for (NSUInteger k = 0; k < n; k++) FCAppendDiagText([@"[高度] " stringByAppendingString:out[k]]);
}

// 异步收集：原生视图树 + 每个 WKWebView 的 DOM 摘要，全部写进诊断文本框
static void FCFillDiagnose(void) {
    FCAppendDiagText(@"===== FC 页面诊断 v47 =====");
    FCAppendDiagText([NSString stringWithFormat:@"顶层VC: %@", NSStringFromClass([FCHostTopVC() class]) ?: @"-"]);
    NSArray<NSString *> *diagUserRules = FCUserRules();
    FCAppendDiagText([NSString stringWithFormat:@"用户规则 %lu 条 / 内置命中 %lu / 被挡节点 %lu（累计动作 %lu 轮）%@",
        (unsigned long)diagUserRules.count, (unsigned long)gFCBuiltinHits,
        (unsigned long)gFCBlockedUnique, (unsigned long)gFCBuiltinBlocked,
        gFCPaused ? @" / 已暂停拦截" : @""]);
    // v32：压0塌陷状态——让用户看清当前有几个窗口被压成0、累计压制多少次（对抗DX重绘）
    NSUInteger zeroNow = 0;
    for (FCFlattenRecord *rec in gFCFlattened) if (rec.zeroCollapsed) zeroNow++;
    NSUInteger srcZero = gFCSourceZeroed ? gFCSourceZeroed.count : 0;
    FCAppendDiagText([NSString stringWithFormat:@"[压0] 当前压平 %lu 个窗口 / 源头压0容器 %lu / 累计重压 %lu 次（原生视图层，非删节点）",
        (unsigned long)zeroNow, (unsigned long)srcZero, (unsigned long)gFCZeroApplied]);
    FCAppendBlankContainerDiag();     // v35/v36：白块候选容器（v36 放宽判据）
    FCAppendCoordinateProbe();        // v36：白块坐标反查——按采样点抓覆盖它的大容器(面积小→大)
    FCAppendZeroedList();             // v36：已压0容器清单——抓「压0后DX重设frame回来」撑白块的那层
    FCAppendHeightOwnerDiag();        // v40：高度归属——spec 值/类型 + 宿主列表 + 归零计数
    // v22：逐条打印规则真实内容 + 类型——老大一眼看清点选到底存了文字还是 cls:/pos: 指纹
    for (NSUInteger i = 0; i < diagUserRules.count; i++) {
        NSString *rule = diagUserRules[i];
        FCAppendDiagText([NSString stringWithFormat:@"  规则%lu[%@]: %@", (unsigned long)(i + 1),
                          FCDiagRuleKind(rule), rule]);
    }
    // v20：引擎图例——让用户看懂每个板块底层是哪类技术，回答「为什么有的选不中」
    FCAppendDiagText(@"[引擎图例] 原生=UIKit控件 / DX动态=阿里DX-Weex原生动态化 / RN=ReactNative / H5=WKWebView内DOM / Flutter / 小程序");
    FCAppendDiagText(@"[提示] 满屏但 DOM空 的 WKWebView 是空壳容器，内容实际是原生/DX，点选按元素真实引擎走。");
    // 1) 原生视图树（v21：自身文字 + 去重 + 限量，解决日志过长发不出去）
    NSArray *rules = FCEffectiveRules();
    NSMutableSet *seen = [NSMutableSet set];       // v21：去重集合
    __block NSUInteger lines = 0;                 // v21：行数上限
    const NSUInteger kMaxDiagLines = 80;          // v21：正文最多 80 行
    for (UIWindow *w in FCAllWindows()) {
        NSString *wc = NSStringFromClass([w class]);
        if ([wc isEqualToString:@"FCBadgeWindow"] || [wc isEqualToString:@"FCPanelWindow"] ||
            [wc isEqualToString:@"FCDiagWindow"]) continue;
        NSMutableArray<UIView *> *q = [NSMutableArray arrayWithObject:w];
        NSUInteger idx = 0;
        while (idx < q.count && idx < 800 && lines < kMaxDiagLines) {
            UIView *v = q[idx++];
            NSString *joined = FCOwnTextOf(v);     // v21：只取自身文字（仅用于显示，不用于判定命中）
            if (joined.length) {
                CGRect r = [v convertRect:v.bounds toView:nil];
                // v22：命中判定改用 FCDiagHitRule（复刻隐藏的真实口径：类名+指纹+子树文字），
                // 不再只用 joined 自身文字——否则隐藏已生效也会误报「命中:无」。
                NSString *matchedRule = FCDiagHitRule(v, rules);
                NSString *matchShow = matchedRule ? [@"✓" stringByAppendingString:matchedRule] : @"无";
                NSString *vcls = NSStringFromClass([v class]);
                FCAdType at = FCAdTypeOfClass(vcls);
                NSString *typeTag = (at != FCAdTypeUnknown)
                    ? [NSString stringWithFormat:@"[类型:%@]", FCAdTypeName(at)] : @"";
                FCEngine eng = FCEngineOfView(v);
                NSString *engTag = [NSString stringWithFormat:@"[%@]", FCEngineName(eng)];
                // v21：去重 key = 类名+文字+量化位置（同元素跨容器不再重复输出）
                NSString *key = [NSString stringWithFormat:@"%@|%@|%.0f,%.0f",
                                 vcls, joined, r.origin.x, r.origin.y];
                if (![seen containsObject:key]) {
                    [seen addObject:key];
                    FCAppendDiagText([NSString stringWithFormat:@"%@%@ %@ | %@ | %.0f,%.0f %.0fx%.0f | 命中:%@",
                        engTag, typeTag, vcls, joined,
                        r.origin.x, r.origin.y, r.size.width, r.size.height, matchShow]);
                    lines++;
                }
            }
            for (UIView *sub in v.subviews) [q addObject:sub];
        }
        if (lines >= kMaxDiagLines) {
            FCAppendDiagText(@"[已截断] 正文达 80 行上限；可用「复制精简」发送要点。");
            break;
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
    // v23：进程内网络取证结果——旁听到的请求 URL（只读，不改包）
    FCAppendDiagText([NSString stringWithFormat:@"----- 网络取证 %@ (%lu 条) -----",
        gFCNetLogOn ? @"开" : @"关", (unsigned long)(gFCNetLog ? gFCNetLog.count : 0)]);
    if (gFCNetLog.count) {
        NSUInteger show = MIN(gFCNetLog.count, 40);
        for (NSUInteger i = 0; i < show; i++)
            FCAppendDiagText([@"[请求] " stringByAppendingString:gFCNetLog[i]]);
        if (gFCNetLog.count > show)
            FCAppendDiagText([NSString stringWithFormat:@"[请求] ...还有 %lu 条(全文复制可见)",
                              (unsigned long)(gFCNetLog.count - show)]);
    } else if (gFCNetLogOn) {
        FCAppendDiagText(@"[请求] 暂未捕获——开启后请操作 App 几秒再诊断");
    }
    // v27：DX 源头取证——只读列类表/方法名，供 Deep 档精准 hook 定位（不改隐藏逻辑）
    FCAppendDiagText(@"----- DX 动态化源头取证（只读）-----");
    FCAppendDXMethodProbe();
#ifdef FC_DEEP_HOOKS
    // v28：源头参数取证——确认广告文案到底在不在 DX 数据里（只旁听，不改行为）
    FCAppendDiagText(@"----- 源头参数取证（Deep档·只读）-----");
    if (gFCProbeHits.count) {
        FCAppendDiagText([NSString stringWithFormat:@"[取证] ★命中广告数据 %lu 条:",
                          (unsigned long)gFCProbeHits.count]);
        for (NSString *line in gFCProbeHits) FCAppendDiagText(line);
    }
    if (gFCProbeLog.count) {
        FCAppendDiagText([NSString stringWithFormat:@"[取证] 普通参数 %lu 条:",
                          (unsigned long)gFCProbeLog.count]);
        for (NSString *line in gFCProbeLog) FCAppendDiagText(line);
    }
    if (!gFCProbeHits.count && !gFCProbeLog.count)
        FCAppendDiagText(@"[取证] 未捕获——请打开有广告的页面停留几秒再诊断");
    if (gFCProbeDropped)
        FCAppendDiagText([NSString stringWithFormat:@"[取证] 另有 %lu 条重复/超限未记",
                          (unsigned long)gFCProbeDropped]);
    // v31：secondfloor 深层文案路径——判定广告文案能否在数据层精准删除
    FCAppendDiagText(@"----- secondfloor 文案深扫（判定item级过滤）-----");
    if (gFCProbeDeep.count) {
        for (NSString *line in gFCProbeDeep) FCAppendDiagText([@"[深扫] " stringByAppendingString:line]);
    } else {
        FCAppendDiagText(@"[深扫] 未捕获 secondfloor 数据——若日志有[源头拦截]secondfloor=已掐断(正常)，否则请留在首页推荐tab几秒再诊断");
    }
#else
    FCAppendDiagText(@"----- 源头参数取证：仅 Deep 档提供（当前 Pure 档零 hook）-----");
#endif
    FCAppendDiagText(@"===== 诊断结束（点顶部「复制精简」粘贴发我，无需截图）=====");
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

    // v21：顶部固定「关闭 / 复制精简 / 复制全文」三按钮，TextView 从 y=92 起不覆盖按钮
    CGFloat barH = 92;
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 10, s.size.width - 32, 28)];
    title.text = @"页面诊断 · 优先点「复制精简」发我";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:14];
    [bg addSubview:title];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(12, 46, 62, 36);
    [close setTitle:@"关闭" forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:14];
    close.backgroundColor = [UIColor colorWithWhite:0.92 alpha:0.18];
    close.layer.cornerRadius = 8;
    [close addTarget:gFCDiagWindow action:@selector(fcCloseDiag) forControlEvents:UIControlEventTouchUpInside];
    [bg addSubview:close];

    UIButton *brief = [UIButton buttonWithType:UIButtonTypeSystem];
    brief.frame = CGRectMake(82, 46, 122, 36);
    [brief setTitle:@"复制精简" forState:UIControlStateNormal];
    brief.titleLabel.font = [UIFont systemFontOfSize:14];
    brief.backgroundColor = [UIColor colorWithRed:0.15 green:0.65 blue:0.35 alpha:0.5];
    brief.layer.cornerRadius = 8;
    [brief addTarget:gFCDiagWindow action:@selector(fcCopyBrief) forControlEvents:UIControlEventTouchUpInside];
    [bg addSubview:brief];

    UIButton *copy = [UIButton buttonWithType:UIButtonTypeSystem];
    copy.frame = CGRectMake(212, 46, 112, 36);
    [copy setTitle:@"复制全文" forState:UIControlStateNormal];
    copy.titleLabel.font = [UIFont systemFontOfSize:14];
    copy.backgroundColor = [UIColor colorWithRed:0.15 green:0.55 blue:0.95 alpha:0.35];
    copy.layer.cornerRadius = 8;
    [copy addTarget:gFCDiagWindow action:@selector(fcCopyDiag) forControlEvents:UIControlEventTouchUpInside];
    [bg addSubview:copy];

    gFCDiagToast = [[UILabel alloc] initWithFrame:CGRectMake(332, 46, s.size.width - 342, 36)];
    gFCDiagToast.textColor = [UIColor colorWithRed:0.5 green:1.0 blue:0.6 alpha:1];
    gFCDiagToast.font = [UIFont systemFontOfSize:11];
    gFCDiagToast.numberOfLines = 2;
    gFCDiagToast.hidden = YES;
    [bg addSubview:gFCDiagToast];

    gFCDiagText = [[UITextView alloc] initWithFrame:CGRectMake(12, barH, s.size.width - 24, s.size.height - barH - 16)];
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
    // v42：进点选先把所有拦截还原、并冻结扫描——页面回到原始样子才点得到广告。
    // 旧行为下目标广告早被自己压成0，那一片是空白，点下去只能命中外层容器 → 「无法选择广告元素」。
    gFCPickFreeze = YES;
    FCRestoreAllBlockedForPicking();
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
    // v42：解冻——下一轮扫描按最新的用户规则重新拦截（新存的 tpl:/cls: 规则立即生效）。
    gFCPickFreeze = NO;
    // v42：把点选当场隐藏的卡片恢复显示，让扫描重新按规则接管；
    // 否则规则清掉后这些 view 永远 hidden，页面缺一块且无从恢复。
    if (gFCPickHidden) {
        for (UIView *v in [gFCPickHidden allObjects]) { @try { v.hidden = NO; } @catch (NSException *e) { } }
        [gFCPickHidden removeAllObjects];
    }
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
    // v47：浮标只放「当前状态」，不放累计动作数。
    // 老大 v46 反馈「原/压 的数字一直在涨」——那三个数里「原」是 gFCNativeHits（每轮扫描都 +1），
    // 「压」把已离树的旧记录也算进去（强引用导致只增不减）。现在：
    //   压 = 当前真正压着、且节点还在窗口里的对象数；
    //   挡 = 当前还在的被挡节点数（弱表，天然只数活的）。
    NSUInteger zeroNow = 0;
    for (FCFlattenRecord *rec in gFCFlattened)
        if (rec.zeroCollapsed && rec.view && rec.view.window) zeroNow++;
    NSUInteger blockedNow = gFCBlockedSeen ? gFCBlockedSeen.count : 0;
    CGFloat whiteH = FCWhiteSpaceEstimate();
    NSString *big = FCBigBlockPassOn() ? @" 大块免压" : @"";
    gFCBadgeLabel.text = [NSString stringWithFormat:
        @"FCv47%@ 规则%lu 压%lu 挡%lu 白%.0fpt%@ | 点我操作 | %@",
        gFCPaused ? @"(暂停)" : @"",
        (unsigned long)FCUserRules().count, (unsigned long)zeroNow,
        (unsigned long)blockedNow, whiteH, big, top];
    gFCBadgeBar.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
}

static void FCShowBadgeMsg(NSString *msg) {
    if (!gFCBadgeLabel) return;
    if (gFCBadgeCollapsed) {
        gFCBadgeCollapsed = NO;
        [gFCBadgeWindow expandBadgeFrame];
    }
    gFCBadgeLabel.text = [@"FCv47 " stringByAppendingString:msg];
    gFCBadgeBar.backgroundColor = [[UIColor colorWithRed:0.1 green:0.5 blue:0.2 alpha:0.85] colorWithAlphaComponent:0.85];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ FCUpdateBadge(); });
}

// 操作菜单：用系统 UIAlertController（present 到顶层 VC），避免自绘触摸冲突
static void FCShowActionMenu(void) {
    UIViewController *top = FCTopViewController();
    if (!top) top = FCHostTopVC();   // v23：黑屏/异常时 keyWindow 取不到，遍历宿主 window 兜底
    if (!top) { FCShowBadgeMsg(@"无顶层页面"); return; }
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"FCAdBlock v47"
                              message:@"选择操作" preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"点选广告元素" style:UIAlertActionStyleDefault
                 handler:^(UIAlertAction *a){ FCPickModeEnter(); }]];
    // v42：一键暂停——把所有拦截还原、停掉扫描，下拉刷新后页面完全原样，随便点选。
    // 「点选广告元素」自带的临时还原够用大部分场景；这个开关是兜底（DX 已渲染的卡片
    // 不会因还原 frame 自动重新 setData，刷新一次才真的回来）。
    [ac addAction:[UIAlertAction actionWithTitle:(gFCPaused ? @"恢复拦截" : @"暂停拦截（恢复原样·用于点选）")
                 style:(gFCPaused ? UIAlertActionStyleDefault : UIAlertActionStyleDestructive)
                 handler:^(UIAlertAction *a){
                     gFCPaused = !gFCPaused;
                     if (gFCPaused) {
                         FCRestoreAllBlockedForPicking();
                         FCShowBadgeMsg(@"已暂停拦截·下拉刷新页面即恢复原样，再点选广告");
                     } else {
                         gFCBadgeCollapsed = NO;
                         FCShowBadgeMsg(@"已恢复拦截·规则即刻生效");
                     }
                     FCUpdateBadge();
                 }]];
    // v43：大块免压——压0 只删内容不减高度，压一块 155pt 的运营位就换回 155pt 白。
    // 打开后高度 >120pt 的运营位整块跳过，页面不再出现大片空白。
    [ac addAction:[UIAlertAction actionWithTitle:(FCBigBlockPassOn() ? @"关闭「大块免压」" : @"开启「大块免压」(>120pt，不压大位)")
                 style:UIAlertActionStyleDefault
                 handler:^(UIAlertAction *a){
                     BOOL on = !FCBigBlockPassOn();
                     [[NSUserDefaults standardUserDefaults] setBool:on forKey:FCBigBlockKey];
                     [[NSUserDefaults standardUserDefaults] synchronize];
                     FCShowBadgeMsg(on ? @"大块免压已开·>120pt 运营位不再压(需重进页面生效)"
                                       : @"大块免压已关·恢复全压(需重进页面生效)");
                     FCUpdateBadge();
                 }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"管理规则（查看/编辑/新增）" style:UIAlertActionStyleDefault
                 handler:^(UIAlertAction *a){ FCShowRulePanel(); }]];
    // v14：诊断当前页面——一次看清运营位在原生还是网页、命中了什么规则
    [ac addAction:[UIAlertAction actionWithTitle:@"诊断当前页面（发给开发者）" style:UIAlertActionStyleDefault
                 handler:^(UIAlertAction *a){ FCShowDiagnose(); }]];
    // v23：进程内网络取证——旁听 App 请求 URL（只读不改包，绕开 SSL Pinning）
    [ac addAction:[UIAlertAction actionWithTitle:gFCNetLogOn ? @"关闭网络取证" : @"开启网络取证(看广告接口)"
                 style:UIAlertActionStyleDefault
                 handler:^(UIAlertAction *a){
                     FCNetProbeToggle();
                     FCShowBadgeMsg(gFCNetLogOn ? @"网络取证已开·操作App后诊断查看" : @"网络取证已关");
                 }]];
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

// v28：源头参数取证 hook（仅 Deep 档）——只旁听参数、不改任何行为。
// 真机证据：DXRootView setData:/setTemplateItem: 是数据入口；Swift DXCardModel 业务方法
// 不暴露 ObjC，源头过滤只能盯这几个 ObjC 方法。先记后调原 IMP，不改返回值/调用顺序。
static NSMutableSet<NSString *> *gFCProbeSeen = nil;

// 只认用户点选的「文字规则」(≥3字)做命中，cls:/pos:/sel:/img: 指纹与短词不参与，防误报
static NSString *FCProbeFlagOf(NSString *s) {
    if (s.length < 3 || s.length > 200) return nil;
    for (NSString *r in FCUserRules()) {
        if ([r hasPrefix:@"cls:"] || [r hasPrefix:@"pos:"] ||
            [r hasPrefix:@"sel:"] || [r hasPrefix:@"img:"] || r.length < 3) continue;
        if ([s rangeOfString:r].location != NSNotFound) return r;
    }
    return nil;
}

// 递归摘要：深度≤2、每层≤4键/2元素、单条单行≤240字；遇命中文案打标记
static NSString *FCProbeDesc(id obj, int depth, NSString *path) {
    if (!obj) return @"(nil)";
    if (depth > 2) return @"…";
    if ([obj isKindOfClass:[NSString class]]) {
        NSString *s = (NSString *)obj;
        NSString *flag = FCProbeFlagOf(s);
        return flag ? [NSString stringWithFormat:@"\"%@\"<<<【命中广告:%@】", s, flag]
                    : (s.length <= 120 ? [NSString stringWithFormat:@"\"%@\"", s]
                                       : [NSString stringWithFormat:@"<文本%lu字>", (unsigned long)s.length]);
    }
    if ([obj isKindOfClass:[NSNumber class]]) return [obj description];
    if ([obj isKindOfClass:[NSArray class]]) {
        NSArray *a = (NSArray *)obj;
        NSMutableString *m = [NSMutableString stringWithFormat:@"数组(%lu)", (unsigned long)a.count];
        for (NSUInteger i = 0; i < MIN(a.count, 2); i++)
            [m appendFormat:@" %@[%lu]=%@", path, (unsigned long)i,
             FCProbeDesc(a[i], depth+1, [path stringByAppendingFormat:@"[%lu]", (unsigned long)i])];
        return m;
    }
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = (NSDictionary *)obj;
        NSMutableString *m = [NSMutableString stringWithFormat:@"字典(%lu键)", (unsigned long)d.count];
        NSUInteger k = 0;
        for (id key in d) {
            if (k++ >= 4) break;
            NSString *ks = [[key description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
            [m appendFormat:@" %@.%@=%@", path, ks,
             FCProbeDesc(d[key], depth+1, [path stringByAppendingFormat:@".%@", ks])];
        }
        return m;
    }
    NSString *ds = [[obj description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    if (ds.length > 80) ds = [ds substringToIndex:80];
    return [NSString stringWithFormat:@"<%p %@:%@>", obj, NSStringFromClass([obj class]), ds];
}

// v31：深层文案路径取证——递归到第8层，把命中用户广告规则的字符串连同完整 key 路径
// 打出来。目的：判断「领券中心/待使用/消费券」文案在不在 setData 数据里；在→可做 item 级
// 精准删除（只删那张券不碰我的订单），不在→文案写死在远程模板 zip 里，只能视图层处理。
static void FCProbeDeepWalk(id obj, int depth, NSString *path, NSMutableArray *out, NSUInteger *count) {
    if (!obj || *count >= 24 || depth > 8) return;
    if ([obj isKindOfClass:[NSString class]]) {
        NSString *s = (NSString *)obj;
        if (s.length < 2 || s.length > 120) return;
        NSString *flag = FCProbeFlagOf(s);
        if (!flag) return;
        [out addObject:[NSString stringWithFormat:@"%@ = \"%@\"  <<命中:%@",
                        path, s.length > 40 ? [s substringToIndex:40] : s, flag]];
        (*count)++;
    } else if ([obj isKindOfClass:[NSArray class]]) {
        NSArray *a = (NSArray *)obj;
        for (NSUInteger i = 0; i < a.count && *count < 24; i++)
            FCProbeDeepWalk(a[i], depth+1, [path stringByAppendingFormat:@"[%lu]", (unsigned long)i], out, count);
    } else if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = (NSDictionary *)obj;
        for (id key in d) {
            if (*count >= 24) break;
            NSString *ks = [[key description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
            FCProbeDeepWalk(d[key], depth+1, [path stringByAppendingFormat:@".%@", ks], out, count);
        }
    }
}

static void FCProbeRecord(NSString *tag, id value) {
    NSString *info = [FCProbeDesc(value, 0, @"data") stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    if (info.length > 240) info = [info substringToIndex:240];
    if (!gFCProbeSeen) gFCProbeSeen = [NSMutableSet set];
    if (gFCProbeSeen.count > 500) return;                 // 去重表上限，防长会话内存膨胀
    NSString *key = [tag stringByAppendingString:info];
    if ([gFCProbeSeen containsObject:key]) return;
    [gFCProbeSeen addObject:key];
    NSString *line = [NSString stringWithFormat:@"[%@] %@", tag, info];
    BOOL hit = [info rangeOfString:@"【命中广告:"].location != NSNotFound;
    NSMutableArray *bucket = hit ? gFCProbeHits : gFCProbeLog;
    NSUInteger cap = hit ? 10 : 12;
    if (!bucket) {
        if (hit) gFCProbeHits = [NSMutableArray array]; else gFCProbeLog = [NSMutableArray array];
        bucket = hit ? gFCProbeHits : gFCProbeLog;
    }
    if (bucket.count < cap) [bucket addObject:line]; else gFCProbeDropped++;
}

// 只 hook 类「自身实现」的方法，避免 class_getInstanceMethod 命中父类后误改父类实现
static Method FCOwnMethod(Class c, NSString *name) {
    SEL s = NSSelectorFromString(name);
    unsigned int n = 0; Method *list = class_copyMethodList(c, &n);
    Method found = nil;
    for (unsigned int i = 0; i < n; i++)
        if (method_getName(list[i]) == s) { found = list[i]; break; }
    if (list) free(list);
    return found;
}

static IMP gFCOrigSetData = nil;
static IMP gFCOrigSetTemplate = nil;
static IMP gFCOrigSetViewModel = nil;
static IMP gFCOrigSetHeightSpec = nil;   // v40：DX 高度规格 setter 原实现
static BOOL gFCDeepScanned = NO;   // v31：secondfloor 深扫只做一次，避免刷屏

// v37：kFCBlockedRoot 已前移到全局压0记录区，扫描阶段据此判定源头拦截过的 root。

#pragma mark - v40：高度规格 hook（Deep 档）

static void FCHookSetHeightSpec(id self, SEL _cmd, id spec) {
    // v41：重入保护——我们给原 IMP 传 @0 后，若原实现内部又回调本 setter，
    // 没有这道闸就会无限递归（表现为栈爆/随机崩）。重入时一律原样透传。
    static BOOL inHeightHook = NO;
    if (inHeightHook) {
        if (gFCOrigSetHeightSpec) ((void (*)(id, SEL, id))gFCOrigSetHeightSpec)(self, _cmd, spec);
        return;
    }
    // 已判定拦截的实例：无论谁在什么时候设高度，一律压成 0 —— 从布局源头掐掉那个空槽。
    BOOL blocked = NO;
    @try {
        blocked = (objc_getAssociatedObject(self, &kFCBlockedRoot) != nil);
        if (!blocked) blocked = (objc_getAssociatedObject(self, &kFCZeroRec) != nil);
    } @catch (NSException *e) { }
    if (blocked && [spec isKindOfClass:[NSNumber class]] && [spec doubleValue] > 0.5) {
        inHeightHook = YES;
        if (gFCOrigSetHeightSpec) ((void (*)(id, SEL, id))gFCOrigSetHeightSpec)(self, _cmd, @0);
        inHeightHook = NO;
        gFCHeightZeroOK++;
        // v41：只入队。v40 在这里同步 invalidateLayout，撞上 cell 配置期 → 野指针闪退。
        FCEnqueueRelayout((UIView *)self);
        return;
    }
    // v41：不再对 spec 做 FCProbeRecord/[description] 内省——DX 半初始化对象上
    // 读属性可能拿到垃圾指针并被 ARC retain（本次闪退的另一条同类路径）。
    if (gFCOrigSetHeightSpec) ((void (*)(id, SEL, id))gFCOrigSetHeightSpec)(self, _cmd, spec);
}

static void FCHookSetData(id self, SEL _cmd, id data) {
    // v42：暂停拦截期间一律放行——老大要看到原始页面才能点选广告。
    if (gFCPaused) { if (gFCOrigSetData) ((void (*)(id, SEL, id))gFCOrigSetData)(self, _cmd, data); return; }
    // v33：联动拦截——若本实例的 setTemplateItem 已命中 tpl:/内置模板并 return（模板没设），
    // 这里也必须 return，否则数据灌进一个没有模板的半初始化 DXRootView，反而可能异常渲染。
    if (objc_getAssociatedObject(self, &kFCBlockedRoot)) return;
    // v29：源头拦截——模板名命中 tpl: 规则就不把数据喂给 DX 引擎，卡片无从渲染/重绘。
    // 只精确匹配用户点选的模板；命中即 return，未命中照常调原 IMP（行为不变）。
    NSString *tpl = FCTplNameFromData(data);
    // v30：建立「实例→模板名」映射，供点选直接查表（不依赖 KVC 读属性）
    if (tpl.length) FCTplBridgePut((UIView *)self, tpl);
    if (tpl.length && FCTplIsBlocked(tpl)) {
        if (!gFCBlockedRoots) gFCBlockedRoots = [NSHashTable weakObjectsHashTable];
        [gFCBlockedRoots addObject:(UIView *)self];   // v42：登记，暂停拦截时逐个清标记
        objc_setAssociatedObject(self, &kFCBlockedRoot, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        FCProbeRecord(@"源头拦截", tpl);
        FCLog(@"源头拦截模板(setData): %@", tpl);
        return;
    }
    // v31：secondfloor 深扫一次——把广告文案的完整 key 路径打出来，判定能否 item 级精准删
    if (!gFCDeepScanned && tpl && [tpl rangeOfString:@"secondfloor"].location != NSNotFound) {
        gFCDeepScanned = YES;
        NSMutableArray *deep = [NSMutableArray array];
        NSUInteger cnt = 0;
        @try { FCProbeDeepWalk(data, 0, tpl, deep, &cnt); } @catch (NSException *e) { }
        gFCProbeDeep = deep.count ? deep : [NSMutableArray arrayWithObject:@"(数据里未找到广告文案——文案写在远程模板zip,需视图层处理)"];
    }
    @try { FCProbeRecord(@"DXRootView.setData", data); } @catch (NSException *e) { }
    if (gFCOrigSetData) ((void (*)(id, SEL, id))gFCOrigSetData)(self, _cmd, data);
}
static void FCHookSetTemplate(id self, SEL _cmd, id tpl) {
    // v30：setTemplateItem 的对象名最完整（含版本），优先刷进 bridge
    NSString *n = FCTplNameFromItem(tpl);
    if (n.length) FCTplBridgePut((UIView *)self, n);
    // v42：暂停拦截期间不拦模板，照常交给 DX 渲染
    if (gFCPaused) { if (gFCOrigSetTemplate) ((void (*)(id, SEL, id))gFCOrigSetTemplate)(self, _cmd, tpl); return; }
    @try { FCProbeRecord(@"DXRootView.setTemplateItem", tpl); } @catch (NSException *e) { }
    // v33 关键修复：88 横幅等卡片的模板名只在 setTemplateItem: 出现，setData: 数据里是空模板，
    // 所以 v29~v32 只拦 setData 时日志显示「源头拦截命中」但横幅照常完整渲染。
    // 这里命中即不设模板（不调原 IMP）+ 打实例标记，从源头掐断渲染链路。
    if (n.length && FCTplIsBlocked(n)) {
        if (!gFCBlockedRoots) gFCBlockedRoots = [NSHashTable weakObjectsHashTable];
        [gFCBlockedRoots addObject:(UIView *)self];   // v42：登记，暂停拦截时逐个清标记
        objc_setAssociatedObject(self, &kFCBlockedRoot, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        FCProbeRecord(@"源头拦截", n);
        FCLog(@"源头拦截模板(setTemplateItem): %@", n);
        return;
    }
    // v33 复用自愈：DXRootView 会被拿去复用渲染别的模板；这次模板名不命中就清掉旧标记，
    // 否则实例一旦拦过一次，之后所有正常卡片都会因残留标记被 setData 误拦（整块空白）。
    if (objc_getAssociatedObject(self, &kFCBlockedRoot))
        objc_setAssociatedObject(self, &kFCBlockedRoot, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (gFCOrigSetTemplate) ((void (*)(id, SEL, id))gFCOrigSetTemplate)(self, _cmd, tpl);
}
static void FCHookSetViewModel(id self, SEL _cmd, id vm) {
    @try { FCProbeRecord(@"DXScrollerLayoutCell.setViewModel", vm); } @catch (NSException *e) { }
    if (gFCOrigSetViewModel) ((void (*)(id, SEL, id))gFCOrigSetViewModel)(self, _cmd, vm);
}

static void FCInstallProbeHooks(void) {
    Class root = NSClassFromString(@"DXRootView");
    if (root) {
        Method m = FCOwnMethod(root, @"setData:");
        if (m) { gFCOrigSetData = method_getImplementation(m); method_setImplementation(m, (IMP)FCHookSetData); }
        Method t = FCOwnMethod(root, @"setTemplateItem:");
        if (t) { gFCOrigSetTemplate = method_getImplementation(t); method_setImplementation(t, (IMP)FCHookSetTemplate); }
        // v40：高度规格 setter——把被拦运营位的高度从布局源头置 0
        Method hs = FCOwnMethod(root, @"setOriginalHeightSpec:");
        // v41：先验签名，参数必须是对象(@)。万一宿主把它写成 C 结构体（CGSize/WXLength 传值），
        // 用 id 签名去调会把栈搅烂——宁可不 hook，也不能崩。
        const char *hsEnc = hs ? method_getTypeEncoding(hs) : NULL;
        gFCHeightSetEnc = hsEnc ? [NSString stringWithUTF8String:hsEnc] : nil;
        NSMethodSignature *hsSig = nil;
        if (hsEnc) { @try { hsSig = [NSMethodSignature signatureWithObjCTypes:hsEnc]; } @catch (NSException *e) { } }
        BOOL hsOK = (hsSig && hsSig.numberOfArguments >= 3 && [hsSig getArgumentTypeAtIndex:2][0] == '@');
        if (hs && hsOK) {
            gFCOrigSetHeightSpec = method_getImplementation(hs);
            method_setImplementation(hs, (IMP)FCHookSetHeightSpec);
        }
        FCLog(@"v41 高度 setter hook=%d(签名%@) enc=%@", hs ? 1 : 0,
              hsOK ? @"对象·已挂" : @"非对象·已跳过", gFCHeightSetEnc ? gFCHeightSetEnc : @"?");
    }
    Class cell = NSClassFromString(@"DXScrollerLayoutCell");
    if (cell) {
        Method m = FCOwnMethod(cell, @"setViewModel:");
        if (m) { gFCOrigSetViewModel = method_getImplementation(m); method_setImplementation(m, (IMP)FCHookSetViewModel); }
    }
    FCLog(@"v28 源头取证钩子 root=%d cell=%d", root != nil, cell != nil);
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
    FCInstallProbeHooks();   // v28：源头参数取证（只旁听、不改行为）
}
#endif

#pragma mark - 入口

__attribute__((constructor))
static void FCAdBlockInit(void) {
    @autoreleasepool {
        FCLog(@"v47 载入，Bundle=%@", [[NSBundle mainBundle] bundleIdentifier]);
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

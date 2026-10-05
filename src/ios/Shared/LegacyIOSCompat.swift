//
//  LegacyIOSCompat.swift
//  Minis
//
//  iOS 15.4 向后兼容层 —— 本文件不属于上游 OpenMinis 源码。
//
//  上游基线部署目标为 iOS 16.0（AgentWidget 为 16.2），本层把 iOS 16 / iOS 17
//  才引入的 SwiftUI API 包装成在 iOS 15.4 上可用的等价实现，使整个工程可以
//  把 IPHONEOS_DEPLOYMENT_TARGET 下调到 15.4。
//
//  设计原则：
//   1. iOS 16+ 上的行为与上游逐字节等价 —— 全部直接转发到系统 API，
//      不做任何语义改写，因此本层不会让新系统上的表现退化。
//   2. iOS 15 上退化为最接近的等价实现；确实没有等价物的装饰性 API
//      降级为 no-op（不影响布局与功能）。
//   3. 只提供「改名转发」型 shim。凡是需要在 iOS 15 上换一套导航模型的地方
//      （path 导航、NavigationSplitView）都在调用点用 #available 显式分支，
//      不在本层里做隐式行为替换。
//

import SwiftUI
import UIKit
import UserNotifications
import FileProvider
import PhotosUI
import UniformTypeIdentifiers

// MARK: - 版本常量

enum MinisCompat {
    /// 本分支支持的最低 iOS 版本。
    static let minimumSupportedIOS = "15.4"

    /// 当前是否运行在 iOS 15 这条回退路径上。
    static var isLegacyRuntime: Bool {
        if #available(iOS 16.0, *) { return false }
        return true
    }
}

// MARK: - 1. NavigationStack

/// `NavigationStack` 的兼容版本。
///
/// iOS 16+ 直接使用系统 `NavigationStack`；iOS 15 使用 `NavigationView`
/// 加 `.stack` 样式，二者在「无 path 的单列推入」场景下行为一致。
///
/// 注意：本 shim 只覆盖**不带 path 绑定**的用法。带 path 的调用点必须
/// 使用 `MinisNavStackPath`，并在 iOS 15 上走 `MinisLegacyCompactStack`。
struct MinisNavStack<Content: View>: View {
    private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        if #available(iOS 16.0, *) {
            NavigationStack { content() }
        } else {
            NavigationView { content() }
                .navigationViewStyle(.stack)
        }
    }
}

/// 带 `[D]` 路径绑定的 `NavigationStack` 兼容版本。
///
/// 上游使用 `NavigationPath`（iOS 16+）作为路径类型；本移植把路径统一换成
/// 具体类型的数组 `[D]`，`NavigationStack(path:)` 与数组天然兼容，因此
/// iOS 16+ 行为不变，同时 iOS 15 上至少不会因为 `NavigationPath` 不存在而
/// 编译失败。
struct MinisNavStackPath<D: Hashable, Content: View>: View {
    @Binding private var path: [D]
    private let content: () -> Content

    init(path: Binding<[D]>, @ViewBuilder content: @escaping () -> Content) {
        self._path = path
        self.content = content
    }

    var body: some View {
        if #available(iOS 16.0, *) {
            NavigationStack(path: $path) { content() }
        } else {
            // iOS 15 没有值路由。这里退化为普通 NavigationView：调用点若需要
            // 真正的单层推入，应改用 MinisLegacyCompactStack。
            NavigationView { content() }
                .navigationViewStyle(.stack)
        }
    }
}

// MARK: - 2. navigationDestination

extension View {
    /// `navigationDestination(for:destination:)` 的兼容版本。
    ///
    /// iOS 15 上是 no-op —— 该版本的 NavigationView 不支持值路由。
    @ViewBuilder
    func minisNavigationDestination<D: Hashable, C: View>(
        for data: D.Type,
        @ViewBuilder destination: @escaping (D) -> C
    ) -> some View {
        if #available(iOS 16.0, *) {
            self.navigationDestination(for: data, destination: destination)
        } else {
            self
        }
    }
}

// MARK: - 3. iOS 15 紧凑布局回退栈

/// iOS 15 上替代 `NavigationStack(path:)` 的单层导航容器。
///
/// 上游 iPhone 紧凑布局的路径深度实际恒为 1（路径里只放一个 sessionId），
/// 因此可以用「有选中项就显示详情、否则显示列表」的方式等价替代，
/// 不需要 NavigationView 的值路由能力。
///
/// 复用上游已经存在的 iPad 双列实现（列表 + detailView），因此不引入
/// 新的视图状态机。
/// iOS 15 的单层导航栈回退实现。
///
/// 上游 iPhone 紧凑布局的路径深度恒为 1（会话列表 → 会话详情），
/// 而 iOS 15 没有值路由（NavigationStack(path:) / navigationDestination /
/// NavigationLink(value:)），因此这里用「NavigationView + 程序化
/// NavigationLink(isActive:)」做等价的单层推入。
///
/// **关键：必须包在 NavigationView 内。**
/// 详情视图的 `.toolbar`（设置菜单、终端图标等）依赖 NavigationView 祖先才能渲染；
/// 早期实现用裸 `VStack` 切换内容，导致详情页工具栏整体消失 —— 表现为
/// 「设置没了、终端图标没了」，且系统导航栏也不存在。
///
/// 点击驱动：`selection` 由调用方写入（见 ContentView 的 `tapToSelect`）。
struct MinisLegacyCompactStack<Root: View, Detail: View>: View {
    @Binding private var selection: String?
    private let root: () -> Root
    private let detail: (String) -> Detail

    init(
        selection: Binding<String?>,
        @ViewBuilder root: @escaping () -> Root,
        @ViewBuilder detail: @escaping (String) -> Detail
    ) {
        self._selection = selection
        self.root = root
        self.detail = detail
    }

    /// 把 `selection != nil` 映射成 NavigationLink 的激活状态；
    /// 用户点系统返回按钮时回写 `selection = nil`。
    private var isDetailActive: Binding<Bool> {
        Binding(
            get: { selection != nil },
            set: { newValue in
                if !newValue { selection = nil }
            }
        )
    }

    var body: some View {
        NavigationView {
            root()
                .background(
                    NavigationLink(isActive: isDetailActive) {
                        if let id = selection {
                            detail(id)
                        }
                    } label: {
                        EmptyView()
                    }
                    .hidden()
                )
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - 4. LabeledContent

/// `LabeledContent` 的兼容版本。
///
/// iOS 16+ 转发到系统实现；iOS 15 退化为 `HStack`（标签左、内容右），
/// 与系统默认样式在观感上一致。
struct MinisLabeledContent<Label: View, Content: View>: View {
    private let label: Label
    private let content: Content

    init(label: Label, content: Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        if #available(iOS 16.0, *) {
            LabeledContent { content } label: { label }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                label
                Spacer(minLength: 8)
                content
            }
        }
    }
}

extension MinisLabeledContent {
    /// `MinisLabeledContent { 内容 } label: { 标签 }` —— 自定义标签与自定义内容。
    init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.init(label: label(), content: content())
    }

    /// `LabeledContent("标题") { 自定义内容 }` —— 字面量标题，走本地化。
    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) where Label == Text {
        self.init(label: Text(title), content: content())
    }

    /// `LabeledContent(某个 String) { 自定义内容 }` —— 已经是本地化结果，不再二次本地化。
    init<S: StringProtocol>(_ title: S, @ViewBuilder content: () -> Content) where Label == Text {
        self.init(label: Text(title), content: content())
    }

    /// `LabeledContent("标题", value: "值")` —— 字面量标题，走本地化。
    init(_ title: LocalizedStringKey, value: String) where Label == Text, Content == Text {
        self.init(label: Text(title), content: Text(value))
    }

    /// `LabeledContent(某个 String, value: "值")`。
    init<S: StringProtocol>(_ title: S, value: String) where Label == Text, Content == Text {
        self.init(label: Text(title), content: Text(value))
    }
}

// MARK: - 5. 工具栏相关（iOS 16 / 17）

extension ToolbarItemPlacement {
    /// iOS 17 的 `.topBarTrailing`，在 iOS 15/16 上回退为 `.navigationBarTrailing`。
    static var minisTopBarTrailing: ToolbarItemPlacement {
        if #available(iOS 17.0, *) { return .topBarTrailing }
        return .navigationBarTrailing
    }

    /// iOS 17 的 `.topBarLeading`，在 iOS 15/16 上回退为 `.navigationBarLeading`。
    static var minisTopBarLeading: ToolbarItemPlacement {
        if #available(iOS 17.0, *) { return .topBarLeading }
        return .navigationBarLeading
    }
}

extension View {
    /// `toolbarBackground(_:for:)` 的兼容版本（只覆盖 `.navigationBar`）。
    @ViewBuilder
    func minisToolbarBackground<S: ShapeStyle>(_ style: S) -> some View {
        if #available(iOS 16.0, *) {
            self.toolbarBackground(style, for: .navigationBar)
        } else {
            self
        }
    }

    /// `toolbarBackground(_:for:)` 的 `Visibility` 重载。
    @ViewBuilder
    func minisToolbarBackground(_ visibility: Visibility) -> some View {
        if #available(iOS 16.0, *) {
            self.toolbarBackground(visibility, for: .navigationBar)
        } else {
            self
        }
    }
}

// MARK: - 6. Sheet 相关（iOS 16）

/// `PresentationDetent` 的兼容版本。
///
/// 系统 `PresentationDetent` 是 iOS 16+ 类型，所以这里用自建枚举承载调用点
/// 的 `.medium / .large / .fraction(_) / .height(_)` 写法。
enum MinisPresentationDetent: Hashable {
    case medium
    case large
    case fraction(CGFloat)
    case height(CGFloat)

    @available(iOS 16.0, *)
    var sdkValue: PresentationDetent {
        switch self {
        case .medium: return .medium
        case .large: return .large
        case .fraction(let value): return .fraction(value)
        case .height(let value): return .height(value)
        }
    }

    /// 反向映射：系统 `PresentationDetent` → 本枚举。
    /// 只覆盖本工程实际用到的几种；其余（如 `.height` 之外的动态值）返回 nil。
    @available(iOS 16.0, *)
    init?(sdk: PresentationDetent) {
        if sdk == .medium {
            self = .medium
        } else if sdk == .large {
            self = .large
        } else {
            return nil
        }
    }
}

extension View {
    /// `presentationDetents(_:)` 的兼容版本。iOS 15 上是 no-op ——
    /// 该版本没有自定义 detent 能力，sheet 保持系统默认高度。
    @ViewBuilder
    func minisPresentationDetents(_ detents: Set<MinisPresentationDetent>) -> some View {
        if #available(iOS 16.0, *) {
            self.presentationDetents(Set(detents.map { $0.sdkValue }))
        } else {
            self
        }
    }

    /// `presentationDetents(_:selection:)` 的兼容版本（带当前档位绑定）。
    @ViewBuilder
    func minisPresentationDetents(
        _ detents: Set<MinisPresentationDetent>,
        selection: Binding<MinisPresentationDetent>
    ) -> some View {
        if #available(iOS 16.0, *) {
            self.presentationDetents(
                Set(detents.map { $0.sdkValue }),
                selection: Binding<PresentationDetent>(
                    get: { selection.wrappedValue.sdkValue },
                    set: { newValue in
                        if let mapped = MinisPresentationDetent(sdk: newValue) {
                            selection.wrappedValue = mapped
                        }
                    }
                )
            )
        } else {
            self
        }
    }

    /// `presentationDragIndicator(_:)` 的兼容版本。iOS 15 上是 no-op。
    @ViewBuilder
    func minisPresentationDragIndicator(_ visibility: Visibility) -> some View {
        if #available(iOS 16.0, *) {
            self.presentationDragIndicator(visibility)
        } else {
            self
        }
    }
}

// MARK: - 7. 滚动相关（iOS 16）

extension View {
    /// `scrollContentBackground(_:)` 的兼容版本。iOS 15 上是 no-op。
    @ViewBuilder
    func minisScrollContentBackground(_ visibility: Visibility) -> some View {
        if #available(iOS 16.0, *) {
            self.scrollContentBackground(visibility)
        } else {
            self
        }
    }

    /// `scrollIndicators(_:)` 的兼容版本。iOS 15 上是 no-op。
    ///
    /// 注意：`Visibility` 与 `ScrollIndicatorVisibility` 是两个不同的类型，
    /// 不能直接互传，需要显式映射。
    @ViewBuilder
    func minisScrollIndicators(_ visibility: Visibility) -> some View {
        if #available(iOS 16.0, *) {
            self.scrollIndicators(visibility == .visible ? .visible : .hidden)
        } else {
            self
        }
    }

    /// `scrollDismissesKeyboard(_:)` 的兼容版本。iOS 15 上是 no-op。
    @ViewBuilder
    func minisScrollDismissesKeyboard(_ mode: MinisScrollDismissesKeyboardMode) -> some View {
        if #available(iOS 16.0, *) {
            self.scrollDismissesKeyboard(mode.sdkValue)
        } else {
            self
        }
    }

    /// `persistentSystemOverlays(_:)` 的兼容版本。iOS 15 上是 no-op。
    @ViewBuilder
    func minisPersistentSystemOverlays(_ visibility: Visibility) -> some View {
        if #available(iOS 16.0, *) {
            self.persistentSystemOverlays(visibility)
        } else {
            self
        }
    }
}

/// `ScrollDismissesKeyboardMode` 的兼容版本（系统类型为 iOS 16+）。
enum MinisScrollDismissesKeyboardMode {
    case automatic
    case immediately
    case interactively
    case never

    @available(iOS 16.0, *)
    var sdkValue: ScrollDismissesKeyboardMode {
        switch self {
        case .automatic: return .automatic
        case .immediately: return .immediately
        case .interactively: return .interactively
        case .never: return .never
        }
    }
}

// MARK: - 8. View.bold()

extension View {
    /// `View.bold()`（iOS 16+）的兼容版本。
    ///
    /// iOS 15 上退化为 no-op：该版本既没有 `View.bold()`，也没有
    /// `View.fontWeight()`（后者同为 iOS 16+，只有 `Text.fontWeight` 是 iOS 13+，
    /// 而本 shim 的 `self` 是泛型 `View`，落不到 `Text` 那个重载上）。
    ///
    /// 全工程只有 3 处调用（2 个 Button + 1 个已显式设过字体的视图），
    /// 在 iOS 15 上仅表现为这几处文字不加粗，不影响布局与功能。
    /// 之所以不用 `.font(.body.bold())` 兜底：那会把字号强制成 body，
    /// 覆盖调用点已有的字体设置，反而引入可见的观感偏差。
    @ViewBuilder
    func minisBold() -> some View {
        if #available(iOS 16.0, *) {
            self.bold()
        } else {
            self
        }
    }
}

// MARK: - 9. 符号动画（iOS 17）

extension View {
    /// `symbolEffect(.pulse)`（iOS 17+）的兼容版本。iOS 15/16 上是 no-op。
    @ViewBuilder
    func minisSymbolEffectPulse() -> some View {
        if #available(iOS 17.0, *) {
            self.symbolEffect(.pulse)
        } else {
            self
        }
    }

    /// `symbolEffect(.pulse, options: .repeating, isActive:)` 的兼容版本。
    @ViewBuilder
    func minisSymbolEffectPulseRepeating(isActive: Bool) -> some View {
        if #available(iOS 17.0, *) {
            self.symbolEffect(.pulse, options: .repeating, isActive: isActive)
        } else {
            self
        }
    }
}

// MARK: - 11. 类型擦除形状（iOS 16 的 AnyShape / UnevenRoundedRectangle）

/// `AnyShape`（iOS 16+）的兼容版本。
///
/// 用「把 `path(in:)` 闭包存下来」的方式做类型擦除，因此不依赖 iOS 16。
/// 在所有系统版本上行为一致，无需 `#available` 分支。
struct MinisAnyShape: Shape {
    private let pathBuilder: (CGRect) -> Path

    init<S: Shape>(_ shape: S) {
        pathBuilder = { rect in shape.path(in: rect) }
    }

    func path(in rect: CGRect) -> Path {
        pathBuilder(rect)
    }
}

/// `UnevenRoundedRectangle`（iOS 16+）的兼容版本。
///
/// 四角半径独立，用于聊天气泡这类「同侧圆角、相邻侧直角」的形状。
/// 纯 `Path` 构造，iOS 13+ 可用。
struct MinisUnevenRoundedRectangle: Shape {
    var topLeadingRadius: CGFloat = 0
    var bottomLeadingRadius: CGFloat = 0
    var bottomTrailingRadius: CGFloat = 0
    var topTrailingRadius: CGFloat = 0
    /// 与系统 `UnevenRoundedRectangle` 保持参数一致；本实现按连续圆角绘制。
    var style: RoundedCornerStyle = .continuous

    func path(in rect: CGRect) -> Path {
        let limit = min(rect.width, rect.height) / 2
        let tl = min(max(topLeadingRadius, 0), limit)
        let bl = min(max(bottomLeadingRadius, 0), limit)
        let br = min(max(bottomTrailingRadius, 0), limit)
        let tr = min(max(topTrailingRadius, 0), limit)

        var path = Path()

        // 从左上角之后开始，顺时针走一圈
        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        if tr > 0 {
            path.addArc(center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr),
                        radius: tr,
                        startAngle: .degrees(-90), endAngle: .degrees(0),
                        clockwise: false)
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        if br > 0 {
            path.addArc(center: CGPoint(x: rect.maxX - br, y: rect.maxY - br),
                        radius: br,
                        startAngle: .degrees(0), endAngle: .degrees(90),
                        clockwise: false)
        }
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        if bl > 0 {
            path.addArc(center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl),
                        radius: bl,
                        startAngle: .degrees(90), endAngle: .degrees(180),
                        clockwise: false)
        }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        if tl > 0 {
            path.addArc(center: CGPoint(x: rect.minX + tl, y: rect.minY + tl),
                        radius: tl,
                        startAngle: .degrees(180), endAngle: .degrees(270),
                        clockwise: false)
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - 12. 更多 iOS 16 视图修饰符

extension View {
    /// `View.fontWeight(_:)`（iOS 16+）的兼容版本。
    ///
    /// iOS 15 无等价物（`Font.weight` 可用，但无法从泛型 `View` 上取回当前字体），
    /// 退化为 no-op。全工程 6 处调用，仅表现为文字不加粗。
    @ViewBuilder
    func minisFontWeight(_ weight: Font.Weight?) -> some View {
        if #available(iOS 16.0, *) {
            self.fontWeight(weight)
        } else {
            self
        }
    }

    /// `toolbar(_:for:)`（iOS 16+）控制导航栏显隐的兼容版本。
    /// iOS 15 回退为 `navigationBarHidden(_:)`。
    @ViewBuilder
    func minisToolbarVisibility(_ visibility: Visibility, for bar: MinisToolbarBar) -> some View {
        if #available(iOS 16.0, *) {
            self.toolbar(visibility, for: bar.sdkValue)
        } else {
            self.navigationBarHidden(visibility == .hidden)
        }
    }

    /// `draggable(_:)`（iOS 16+）的兼容版本。
    ///
    /// 刻意**不做成泛型**：`Transferable` 协议本身是 iOS 16+，把它当作泛型约束
    /// 会让函数本身无法在 iOS 15 上声明。本工程只有 `String` 载荷，故按具体类型提供。
    ///
    /// iOS 15 回退到 `.onDrag`（iOS 13+），因此拖拽在旧系统上**真的可用**，
    /// 而不是退化成 no-op。
    @ViewBuilder
    func minisDraggable(_ payload: String) -> some View {
        if #available(iOS 16.0, *) {
            self.draggable(payload)
        } else {
            self.onDrag { NSItemProvider(object: payload as NSString) }
        }
    }

    /// `dropDestination(for:action:isTargeted:)`（iOS 16+）的兼容版本。
    ///
    /// 同样不做成泛型（理由见上）。iOS 15 上是 no-op：
    /// 该版本只有 `.onDrop(of:isTargeted:perform:)`，其回调拿到的是异步的
    /// `NSItemProvider`，无法在不引入异步加载与类型还原的前提下等价替代。
    /// 影响面：会话行拖入文件夹这一个交互，其它功能不受影响。
    @ViewBuilder
    func minisDropDestination(
        for type: String.Type,
        action: @escaping ([String], CGPoint) -> Bool,
        isTargeted: @escaping (Bool) -> Void = { _ in }
    ) -> some View {
        if #available(iOS 16.0, *) {
            self.dropDestination(for: String.self, action: action, isTargeted: isTargeted)
        } else {
            self
        }
    }

    /// `onGeometryChange(for:of:action:)` 的兼容版本。
    ///
    /// 该 API 在新 SDK 上的可用版本较高，这里保守地用 iOS 18 作为分界，
    /// 更低版本走 `GeometryReader` + `PreferenceKey` 的等价实现 ——
    /// 两条路径都能拿到几何值，只是实现机制不同。
    @ViewBuilder
    func minisOnGeometryChange<T: Equatable>(
        for type: T.Type,
        of transform: @escaping (GeometryProxy) -> T,
        action: @escaping (T) -> Void
    ) -> some View {
        if #available(iOS 18.0, *) {
            self.onGeometryChange(for: type, of: transform, action: action)
        } else {
            self.background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: MinisGeometryValueKey<T>.self,
                        value: transform(proxy)
                    )
                }
                .onPreferenceChange(MinisGeometryValueKey<T>.self) { value in
                    if let value { action(value) }
                }
            )
        }
    }
}

/// `toolbar(_:for:)` 的 bar 参数（系统的 `ToolbarPlacement` 在 iOS 16+ 才有该重载）。
enum MinisToolbarBar {
    case navigationBar
    case tabBar
    case bottomBar

    @available(iOS 16.0, *)
    var sdkValue: ToolbarPlacement {
        switch self {
        case .navigationBar: return .navigationBar
        case .tabBar: return .tabBar
        case .bottomBar: return .bottomBar
        }
    }
}

/// `minisOnGeometryChange` 回退路径用的 PreferenceKey。
struct MinisGeometryValueKey<T: Equatable>: PreferenceKey {
    static var defaultValue: T? { nil }

    static func reduce(value: inout T?, nextValue: () -> T?) {
        if let next = nextValue() { value = next }
    }
}

// MARK: - 14. 应用角标（iOS 16 的 UNUserNotificationCenter.setBadgeCount）

/// `UNUserNotificationCenter.setBadgeCount(_:)`（iOS 16+）的兼容封装。
///
/// iOS 15 回退到 `UIApplication.applicationIconBadgeNumber` —— 该属性在
/// iOS 17 起被废弃，但在 iOS 15 上正是官方做法。
///
/// 注意：本文件同时被编译进 ShareExtension / AgentWidget 扩展目标，
/// 而 `UIApplication.shared` 在 App 扩展中不可用，因此这两个入口标注为
/// `@available(iOSApplicationExtension, unavailable)`。全部调用点
/// （`MinisApp` / `BackgroundKeepAliveManager`）都属于主 App 目标。
enum MinisBadge {
    /// 回调形式（对应 `setBadgeCount(_:withCompletionHandler:)`）。
    @available(iOSApplicationExtension, unavailable)
    static func set(_ count: Int, completion: @escaping (Error?) -> Void) {
        if #available(iOS 16.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(count, withCompletionHandler: completion)
        } else {
            DispatchQueue.main.async {
                UIApplication.shared.applicationIconBadgeNumber = count
                completion(nil)
            }
        }
    }

    /// async 形式（对应 `try await setBadgeCount(_:)`）。
    @available(iOSApplicationExtension, unavailable)
    static func setAsync(_ count: Int) async {
        if #available(iOS 16.0, *) {
            try? await UNUserNotificationCenter.current().setBadgeCount(count)
        } else {
            await MainActor.run {
                UIApplication.shared.applicationIconBadgeNumber = count
            }
        }
    }
}

// MARK: - 15. 上下文菜单预览裁剪形状（iOS 16/17）

extension View {
    /// `.contentShape(.contextMenuPreview, shape)` 的兼容版本。
    ///
    /// 该 API 用于给「长按预览」单独指定裁剪形状；iOS 15 无此能力，
    /// 退化为 no-op —— 仅表现为预览沿用默认矩形裁剪，功能不受影响。
    @ViewBuilder
    func minisContextMenuPreviewShape<S: Shape>(_ shape: S) -> some View {
        if #available(iOS 16.0, *) {
            self.contentShape(.contextMenuPreview, shape)
        } else {
            self
        }
    }
}


// MARK: - 16. FileProvider 域管理（iOS 16 的 remove(_:mode:)）

/// `NSFileProviderManager.remove(_:mode:completionHandler:)`（iOS 16+）的兼容封装。
///
/// iOS 15 回退到 iOS 11 的 `remove(_:completionHandler:)`：后者没有
/// `preservedLocation` 概念，因此统一回传 `nil`。调用点本就把
/// `preservedLocation` 当作可选值打印，语义兼容。
enum MinisFileProviderCompat {
    static func removeAll(
        domain: NSFileProviderDomain,
        completion: @escaping (URL?, Error?) -> Void
    ) {
        if #available(iOS 16.0, *) {
            NSFileProviderManager.remove(domain, mode: .removeAll) { url, err in
                completion(url, err)
            }
        } else {
            NSFileProviderManager.remove(domain) { err in
                completion(nil, err)
            }
        }
    }
}

// MARK: - 17. 零散 iOS 16 API

extension View {
    /// `navigationSplitViewColumnWidth(min:ideal:max:)`（iOS 16+）的兼容版本。
    /// iOS 15 没有 NavigationSplitView，无列宽概念，退化为 no-op。
    ///
    /// 注意：系统签名里 `ideal` 是**非可选** `CGFloat`（只有 `min` / `max` 可选），
    /// 这里必须保持一致，否则转发时会报可选值未解包。
    @ViewBuilder
    func minisNavigationSplitViewColumnWidth(min: CGFloat? = nil,
                                             ideal: CGFloat,
                                             max: CGFloat? = nil) -> some View {
        if #available(iOS 16.0, *) {
            self.navigationSplitViewColumnWidth(min: min, ideal: ideal, max: max)
        } else {
            self
        }
    }
}

extension ToolbarItemPlacement {
    /// iOS 16 的 `.secondaryAction`，iOS 15 上回退为 `.automatic`。
    static var minisSecondaryAction: ToolbarItemPlacement {
        if #available(iOS 16.0, *) { return .secondaryAction }
        return .automatic
    }
}

extension Color {
    /// `ShapeStyle.gradient`（iOS 16+）的兼容版本。
    ///
    /// iOS 15 回退为同色的 `LinearGradient` —— 视觉上接近「纯色填充」，
    /// 只是没有 iOS 16 那种基于环境的自动明暗过渡。
    var minisGradient: AnyShapeStyle {
        if #available(iOS 16.0, *) {
            return AnyShapeStyle(self.gradient)
        }
        return AnyShapeStyle(LinearGradient(colors: [self, self],
                                            startPoint: .top, endPoint: .bottom))
    }
}

/// 用 `NSRegularExpression` 实现的等价正则工具。
///
/// 上游用的是 Swift 5.7 的 Regex 字面量（`/…/`）与 `ranges(of:)` / `wholeMatch(of:)`，
/// 这些 API 在运行时需要 iOS 16。本封装在全部系统版本上可用。
enum MinisRegex {
    /// 返回全部匹配区间。
    static func ranges(of pattern: String, in text: String) -> [Range<String.Index>] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .compactMap { Range($0.range, in: text) }
    }

    /// 整体匹配判定（对应 `wholeMatch(of:)`）。
    static func wholeMatch(of pattern: String, in text: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return false
        }
        return m.range.location == 0 && m.range.length == ns.length
    }
}

extension UITextView {
    /// `UITextView(usingTextLayoutManager:)`（iOS 16+）的兼容构造。
    ///
    /// iOS 15 回退到 `UITextView()` —— 该版本只有 TextKit 1，
    /// 没有可选的 TextKit 2 布局管理器。
    static func minisMake(usingTextLayoutManager: Bool) -> UITextView {
        if #available(iOS 16.0, *) {
            return UITextView(usingTextLayoutManager: usingTextLayoutManager)
        }
        return UITextView()
    }
}

// MARK: - 18. 上下文菜单（iOS 16 重载）

extension View {
    /// 上下文菜单的兼容版本（**带自定义长按预览**）。
    ///
    /// 背景：工程里 31 处 `.contextMenu`，其中 27 处是单闭包形式
    /// （`contextMenu(menuItems:)`，iOS 13+），另有 4 处是
    /// `contextMenu { 菜单 } preview: { 预览 }` —— `preview:` 是 iOS 16 才有的，
    /// 这 4 处因此报错。
    ///
    /// iOS 15 回退：**保留菜单本身，只放弃自定义预览**（改用系统默认预览）。
    /// 功能不丢失，仅长按预览卡片的外观退化为默认样式。
    @ViewBuilder
    func minisContextMenu<MenuItems: View, Preview: View>(
        @ViewBuilder menuItems: () -> MenuItems,
        @ViewBuilder preview: () -> Preview
    ) -> some View {
        if #available(iOS 16.0, *) {
            self.contextMenu(menuItems: menuItems, preview: preview)
        } else {
            self.contextMenu(menuItems: menuItems)
        }
    }
}

// MARK: - 19. UIHostingConfiguration（iOS 16）

/// `UIHostingConfiguration`（iOS 16+）的兼容包装。
///
/// 设计成「延迟到最后一刻才决定用哪条路径」：
/// iOS 16+ 转发到系统实现（与上游行为完全一致），iOS 15 走
/// `UIContentConfiguration` + `UIHostingController` 的等价实现。
///
/// 用法上只需把 `cell.applyContentConfiguration(config)` 改成
/// `cell.applyContentConfiguration(config.makeConfiguration())`。
struct MinisHostingConfiguration<Content: View> {
    let content: Content
    var minWidth: CGFloat = 0
    var minHeight: CGFloat = 0

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func minSize(width: CGFloat, height: CGFloat) -> MinisHostingConfiguration {
        var copy = self
        copy.minWidth = width
        copy.minHeight = height
        return copy
    }

    /// 上游调用点传的都是 `.all, 0`；iOS 15 回退路径本身无边距概念。
    func margins(_ edges: Edge.Set, _ length: CGFloat) -> MinisHostingConfiguration {
        self
    }

    /// 生成真正赋给 `contentConfiguration` 的对象。
    func makeConfiguration() -> any UIContentConfiguration {
        if #available(iOS 16.0, *) {
            return UIHostingConfiguration { content }
                .minSize(width: minWidth, height: minHeight)
                .margins(.all, 0)
        }
        return MinisLegacyHostingConfiguration(content: content,
                                               minWidth: minWidth,
                                               minHeight: minHeight)
    }
}

/// iOS 15 回退路径的 `UIContentConfiguration`。
struct MinisLegacyHostingConfiguration<Content: View>: UIContentConfiguration {
    let content: Content
    var minWidth: CGFloat = 0
    var minHeight: CGFloat = 0

    func makeContentView() -> UIView & UIContentView {
        MinisLegacyHostingContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> MinisLegacyHostingConfiguration {
        self
    }
}

/// 用 `UIHostingController` 承载 SwiftUI 内容的 `UIContentView`。
final class MinisLegacyHostingContentView<Content: View>: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { applyConfiguration() }
    }

    private let host: UIHostingController<Content>
    private weak var attachedParent: UIViewController?

    init(configuration: MinisLegacyHostingConfiguration<Content>) {
        self.configuration = configuration
        self.host = UIHostingController(rootView: configuration.content)
        super.init(frame: .zero)

        // 把 hosting controller 作为 **child view controller** 挂上去。
        //
        // 只 addSubview 而不建立父子关系时，hosting controller 的视图不在
        // view-controller 层级里：traitCollection / safeAreaInsets 都是错的，
        // SwiftUI 拿到的是一个尺寸不确定的容器。消息内容用
        // `.frame(maxWidth: .infinity)`，对容器尺寸敏感。
        if let parent = Self.nearestViewController(from: self) {
            parent.addChild(host)
            attachedParent = parent
        }

        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.view.topAnchor.constraint(equalTo: topAnchor),
            host.view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        host.didMove(toParent: attachedParent)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let parent = attachedParent, host.parent === parent {
            host.willMove(toParent: nil)
            host.removeFromParent()
        }
    }

    // MARK: - 尺寸
    //
    // 用 **Auto Layout 约束** 表达尺寸，**不要**手写 systemLayoutSizeFitting。
    //
    // 历史教训（两次回归都出在这里）：
    //   · 改成纯 frame 布局（frame = bounds）后，UIView 默认的
    //     systemLayoutSizeFitting 失去约束依据 → 单元格高度算小 → 单元格重叠。
    //   · 为补高度而手写 systemLayoutSizeFitting 并在其中调用 layoutIfNeeded()
    //     更糟：本方法是从 UICollectionView 的布局过程中被调用的，
    //     强制同步布局会重入集合视图布局，SwiftUI 视图图被并发修改 →
    //     EXC_BAD_ACCESS（崩溃日志里 SelfSizingCell.preferredLayoutAttributesFitting
    //     → AppLogger.emit → Swift 运行期，地址被踩成字符串数据）。
    //
    // 约束方案下，UIKit 走标准链路即可同时得到正确的宽度与高度，
    // 且 systemLayoutSizeFitting 是**纯测量**、不触发布局重入。

    private func applyConfiguration() {
        guard let cfg = configuration as? MinisLegacyHostingConfiguration<Content> else { return }
        host.rootView = cfg.content
    }

    /// 沿 responder 链向上找最近的 view controller（cell → collectionView → VC）。
    private static func nearestViewController(from view: UIView) -> UIViewController? {
        var node: UIResponder? = view
        while let current = node {
            if let vc = current as? UIViewController { return vc }
            if let v = current as? UIView, let vc = v.next as? UIViewController { return vc }
            node = current.next
        }
        return nil
    }
}

// MARK: - 20. PhotosPicker（iOS 16）

/// `PhotosPickerItem`（iOS 16+）的兼容包装。
///
/// iOS 15 上 `.minisPhotosPicker` 是 no-op，因此本包装在旧系统上不会被真正填充：
/// `supportedContentTypes` 恒为空、`itemIdentifier` 恒为 nil、两个 `load…`
/// 方法恒返回 nil。调用方原本就有「加载失败 → 标记占位符失败」的分支，语义自洽。
///
/// 标注 `@available(iOSApplicationExtension, unavailable)`：本文件同时编入
/// ShareExtension / AgentWidget，而 PhotosPicker 只在主 App 使用。
@available(iOSApplicationExtension, unavailable)
struct MinisPhotosPickerItem: Hashable {
    // iOS 16 路径：包装系统的 PhotosPickerItem
    private let sdkStorage: Any?
    // iOS 15 路径：PHPickerViewController 已经把内容加载好，直接携带
    private let legacyData: Data?
    private let legacyVideoURL: URL?
    private let legacyUTIs: [String]

    init() {
        sdkStorage = nil
        legacyData = nil
        legacyVideoURL = nil
        legacyUTIs = []
    }

    @available(iOS 16.0, *)
    init(_ item: PhotosPickerItem) {
        sdkStorage = item
        legacyData = nil
        legacyVideoURL = nil
        legacyUTIs = []
    }

    /// iOS 15 路径（PHPicker 回调里构造）。
    init(legacyData: Data?, legacyVideoURL: URL?, legacyUTIs: [String]) {
        sdkStorage = nil
        self.legacyData = legacyData
        self.legacyVideoURL = legacyVideoURL
        self.legacyUTIs = legacyUTIs
    }

    @available(iOS 16.0, *)
    var sdkItem: PhotosPickerItem? { sdkStorage as? PhotosPickerItem }

    /// iOS 15 上 PHPicker 已给出的视频文件 URL（临时目录副本）。
    var legacyVideoFile: URL? { legacyVideoURL }

    /// `Any?` 不满足 `Hashable`，因此手写等价性。
    static func == (lhs: MinisPhotosPickerItem, rhs: MinisPhotosPickerItem) -> Bool {
        if #available(iOS 16.0, *) {
            return lhs.sdkItem == rhs.sdkItem
        }
        return lhs.legacyVideoURL == rhs.legacyVideoURL && lhs.legacyData == rhs.legacyData
    }

    func hash(into hasher: inout Hasher) {
        if #available(iOS 16.0, *), let item = sdkItem {
            hasher.combine(item)
        } else {
            hasher.combine(legacyVideoURL)
            hasher.combine(legacyData)
        }
    }

    /// 对应 `PhotosPickerItem.supportedContentTypes`。
    var supportedContentTypes: [UTType] {
        if #available(iOS 16.0, *) { return sdkItem?.supportedContentTypes ?? [] }
        return legacyUTIs.compactMap { UTType($0) }
    }

    /// 对应 `PhotosPickerItem.itemIdentifier`。
    var itemIdentifier: String? {
        if #available(iOS 16.0, *) { return sdkItem?.itemIdentifier }
        return nil
    }

    /// 对应 `loadTransferable(type: Data.self)`。
    func loadData() async -> Data? {
        if #available(iOS 16.0, *) {
            guard let item = sdkItem else { return nil }
            return try? await item.loadTransferable(type: Data.self)
        }
        return legacyData
    }
}

/// iOS 15 的照片/视频选择器实现。
///
/// SwiftUI 的 `PhotosPicker` 是 iOS 16 组件，但 **`PHPickerViewController`
/// 从 iOS 14 就有** —— 所以旧系统上不必退化成 no-op，可以直接用它实现完整功能
/// （多选、图片与视频、按 UTI 过滤）。
@available(iOSApplicationExtension, unavailable)
struct MinisLegacyPhotoPicker: UIViewControllerRepresentable {
    var selectionLimit: Int
    var filter: PHPickerFilter
    var onPicked: ([MinisPhotosPickerItem]) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = selectionLimit
        config.filter = filter
        config.preferredAssetRepresentationMode = .current
        let vc = PHPickerViewController(configuration: config)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let parent: MinisLegacyPhotoPicker

        init(_ parent: MinisLegacyPhotoPicker) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !results.isEmpty else {
                parent.onCancel()
                return
            }

            let group = DispatchGroup()
            let lock = NSLock()
            // 按原始顺序占位，避免并发加载打乱顺序。
            var slots = [MinisPhotosPickerItem?](repeating: nil, count: results.count)

            for (index, result) in results.enumerated() {
                let provider = result.itemProvider
                let utis = provider.registeredTypeIdentifiers
                let isVideo = provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)

                group.enter()
                if isVideo {
                    provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                        defer { group.leave() }
                        guard let url else { return }
                        // 回调返回后系统会删除原文件，必须立刻复制到临时目录。
                        let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
                        let tmp = FileManager.default.temporaryDirectory
                            .appendingPathComponent("minis-pick-\(UUID().uuidString).\(ext)")
                        do {
                            try FileManager.default.copyItem(at: url, to: tmp)
                        } catch {
                            return
                        }
                        lock.lock()
                        slots[index] = MinisPhotosPickerItem(legacyData: nil,
                                                             legacyVideoURL: tmp,
                                                             legacyUTIs: utis)
                        lock.unlock()
                    }
                } else {
                    provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                        defer { group.leave() }
                        guard let data else { return }
                        lock.lock()
                        slots[index] = MinisPhotosPickerItem(legacyData: data,
                                                             legacyVideoURL: nil,
                                                             legacyUTIs: utis)
                        lock.unlock()
                    }
                }
            }

            group.notify(queue: .main) {
                self.parent.onPicked(slots.compactMap { $0 })
            }
        }
    }
}

@available(iOSApplicationExtension, unavailable)
extension View {
    /// `.photosPicker(isPresented:selection:maxSelectionCount:matching:)` 的兼容版本，多选形态。
    ///
    /// iOS 16+ 转发到系统 `PhotosPicker`；iOS 15 用 `PHPickerViewController`
    /// 实现同等能力（**不是 no-op**）。
    @ViewBuilder
    func minisPhotosPicker(
        isPresented: Binding<Bool>,
        selection: Binding<[MinisPhotosPickerItem]>,
        maxSelectionCount: Int? = nil,
        matching: PHPickerFilter
    ) -> some View {
        if #available(iOS 16.0, *) {
            self.photosPicker(
                isPresented: isPresented,
                selection: Binding<[PhotosPickerItem]>(
                    get: { selection.wrappedValue.compactMap { $0.sdkItem } },
                    set: { selection.wrappedValue = $0.map { MinisPhotosPickerItem($0) } }
                ),
                maxSelectionCount: maxSelectionCount,
                matching: matching
            )
        } else {
            self.sheet(isPresented: isPresented) {
                MinisLegacyPhotoPicker(
                    selectionLimit: maxSelectionCount ?? 1,
                    filter: matching,
                    onPicked: { items in
                        selection.wrappedValue = items
                        isPresented.wrappedValue = false
                    },
                    onCancel: { isPresented.wrappedValue = false }
                )
                .ignoresSafeArea()
            }
        }
    }

    /// 单选形态。
    @ViewBuilder
    func minisPhotosPicker(
        isPresented: Binding<Bool>,
        selection: Binding<MinisPhotosPickerItem?>,
        matching: PHPickerFilter
    ) -> some View {
        if #available(iOS 16.0, *) {
            self.photosPicker(
                isPresented: isPresented,
                selection: Binding<PhotosPickerItem?>(
                    get: { selection.wrappedValue?.sdkItem },
                    set: { newValue in
                        selection.wrappedValue = newValue.map { MinisPhotosPickerItem($0) }
                    }
                ),
                matching: matching
            )
        } else {
            self.sheet(isPresented: isPresented) {
                MinisLegacyPhotoPicker(
                    selectionLimit: 1,
                    filter: matching,
                    onPicked: { items in
                        selection.wrappedValue = items.first
                        isPresented.wrappedValue = false
                    },
                    onCancel: { isPresented.wrappedValue = false }
                )
                .ignoresSafeArea()
            }
        }
    }
}

// MARK: - 13. ShareLink（iOS 16）

/// `ShareLink`（iOS 16+）的兼容版本。
///
/// iOS 15 退化为「复制到剪贴板」按钮 —— 该版本没有系统分享面板的 SwiftUI 入口，
/// 而 `UIActivityViewController` 在 App 扩展中不可用，因此不能作为通用回退。
struct MinisShareLink: View {
    let item: URL

    var body: some View {
        if #available(iOS 16.0, *) {
            ShareLink(item: item)
        } else {
            Button {
                UIPasteboard.general.url = item
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
        }
    }
}


// MARK: - 10. 转场与 Sheet 尺寸（iOS 16 / 18）

/// `ContentTransition` 的兼容版本（系统类型为 iOS 16+）。
enum MinisContentTransition {
    case numericText
    case interpolate
    case identity

    @available(iOS 16.0, *)
    var sdkValue: ContentTransition {
        switch self {
        case .numericText: return .numericText()
        case .interpolate: return .interpolate
        case .identity: return .identity
        }
    }
}

extension View {
    /// `contentTransition(_:)` 的兼容版本。iOS 15 上是 no-op。
    @ViewBuilder
    func minisContentTransition(_ transition: MinisContentTransition) -> some View {
        if #available(iOS 16.0, *) {
            self.contentTransition(transition.sdkValue)
        } else {
            self
        }
    }

    /// `presentationSizing(.page)`（iOS 18+）的兼容版本。iOS 15/16/17 上是 no-op。
    @ViewBuilder
    func minisPresentationSizingPage() -> some View {
        if #available(iOS 18.0, *) {
            self.presentationSizing(.page)
        } else {
            self
        }
    }
}


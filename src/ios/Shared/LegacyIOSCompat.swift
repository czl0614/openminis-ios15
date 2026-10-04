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
struct MinisLegacyCompactStack<Root: View, Detail: View>: View {
    @Binding private var selection: String?
    private let root: () -> Root
    private let detail: (String) -> Detail
    private let backTitle: String

    init(
        selection: Binding<String?>,
        backTitle: String = "返回",
        @ViewBuilder root: @escaping () -> Root,
        @ViewBuilder detail: @escaping (String) -> Detail
    ) {
        self._selection = selection
        self.backTitle = backTitle
        self.root = root
        self.detail = detail
    }

    var body: some View {
        if let id = selection {
            VStack(spacing: 0) {
                // iOS 15 回退路径没有系统导航栏返回按钮，这里补一条极简顶栏。
                // 只在 iOS 15 上渲染，不影响 iOS 16+。
                HStack(spacing: 6) {
                    Button {
                        selection = nil
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 17, weight: .semibold))
                            Text(backTitle)
                        }
                        .contentShape(Rectangle())
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(.systemBackground))

                Divider()

                detail(id)
            }
        } else {
            root()
        }
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
    /// `LabeledContent { 内容 } label: { 标签 }` —— 自定义标签与自定义内容。
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


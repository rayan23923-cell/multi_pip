import SwiftUI
import TLDesignSystem
import TLDomain
import TLLocalization

public struct BrowserView: View {
    @Bindable private var model: BrowserModel
    @State private var store = WebViewStore()
    @State private var showsTabs = false
    @FocusState private var isAddressFocused: Bool
    @State private var openingURL: URL?

    /// The model is owned by the caller so tabs survive leaving the screen.
    /// `opening` loads a page in a new tab (Resume).
    public init(model: BrowserModel, opening url: URL? = nil) {
        self.model = model
        _openingURL = State(initialValue: url)
    }

    public var body: some View {
        VStack(spacing: 0) {
            addressBar
            Divider()
            content
            Divider()
            bottomBar
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .imageScale(.large)
                .padding(.horizontal, TLSpacing.l)
                .padding(.vertical, TLSpacing.s)
                .background(.bar)
        }
        .navigationTitle(Text(L10nKey.workspaceToolBrowser))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsTabs) {
            BrowserTabsView(model: model) { closed in
                store.remove(closed)
            }
        }
        .onAppear {
            store.onStateChange = { [model] id, state in model.apply(state, to: id) }
            store.retain(only: Set(model.tabs.map(\.id)))
            if let url = openingURL {
                openingURL = nil
                if model.selectedTab.url != nil { model.newTab(url: url) }
                model.addressText = url.absoluteString
                if let url = model.submitAddress() { store.load(url, in: model.selectedTab) }
            }
        }
        .errorAlert(message: $model.errorMessage)
    }

    private var addressBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: TLSpacing.s) {
                Image(systemName: model.selectedTab.url?.scheme == "https" ? "lock.fill" : "globe")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField(L10n.string(.browserAddressPrompt), text: $model.addressText)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($isAddressFocused)
                    .environment(\.layoutDirection, .leftToRight)
                    .accessibilityLabel(Text(L10nKey.browserAddress))
                    .accessibilityIdentifier("browser.address")
                    .onSubmit(go)
                if !model.addressText.isEmpty && isAddressFocused {
                    Button { model.addressText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(L10nKey.commonCancel))
                    .accessibilityIdentifier("browser.clear")
                }
            }
            .padding(.horizontal, TLSpacing.m)
            .padding(.vertical, TLSpacing.s)
            .background(.background.secondary, in: Capsule())
            .padding(.horizontal, TLSpacing.m)
            .padding(.vertical, TLSpacing.s)

            if model.selectedTab.isLoading {
                ProgressView(value: model.selectedTab.progress)
                    .progressViewStyle(.linear)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.selectedTab.url == nil {
            ScrollView {
                TLEmptyState(title: .browserEmptyTitle, message: .browserEmptyMessage, symbolName: "safari")
                    .padding(.top, TLSpacing.xl)
                    .padding(.horizontal, TLSpacing.l)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            BrowserWebView(tab: model.selectedTab, store: store)
                .id(model.selectedTabID)
                .ignoresSafeArea(.container, edges: .bottom)
                .accessibilityIdentifier("browser.page")
        }
    }

    /// Navigation controls. Kept in the content rather than the bottom toolbar so
    /// they lay out and respond the same on every iOS version.
    private var bottomBar: some View {
        HStack {
            Button { store.goBack(model.selectedTabID) } label: {
                TLLabel(.browserBack, systemImage: "chevron.backward")
            }
            .disabled(!model.selectedTab.canGoBack)
            .accessibilityIdentifier("browser.back")
            Spacer()
            Button { store.goForward(model.selectedTabID) } label: {
                TLLabel(.browserForward, systemImage: "chevron.forward")
            }
            .disabled(!model.selectedTab.canGoForward)
            .accessibilityIdentifier("browser.forward")
            Spacer()
            if model.selectedTab.isLoading {
                Button { store.stop(model.selectedTabID) } label: {
                    TLLabel(.browserStop, systemImage: "xmark")
                }
            } else {
                Button { store.reload(model.selectedTabID) } label: {
                    TLLabel(.browserReload, systemImage: "arrow.clockwise")
                }
                .disabled(model.selectedTab.url == nil)
                .accessibilityIdentifier("browser.reload")
            }
            Spacer()
            Menu {
                if let url = model.selectedTab.url {
                    ShareLink(item: url) { TLLabel(.actionShare, systemImage: "square.and.arrow.up") }
                }
                Button { Task { await model.saveCurrentURL() } } label: {
                    if model.isCurrentURLSaved {
                        TLLabel(.commonSaved, systemImage: "checkmark.circle.fill")
                    } else {
                        TLLabel(.browserSaveURL, systemImage: "tray.and.arrow.down")
                    }
                }
                .disabled(model.isCurrentURLSaved)
                .accessibilityIdentifier("browser.save")
            } label: {
                TLLabel(.commonMore, systemImage: "square.and.arrow.up")
            }
            .disabled(model.selectedTab.url == nil)
            .accessibilityIdentifier("browser.share")
            Spacer()
            Button { showsTabs = true } label: {
                Label {
                    Text(L10nKey.browserTabs)
                } icon: {
                    Image(systemName: "square.on.square")
                        .overlay {
                            Text(verbatim: "\(model.tabs.count)")
                                .font(.system(size: 9, weight: .bold))
                        }
                }
            }
            .accessibilityValue(Text(verbatim: "\(model.tabs.count)"))
            .accessibilityIdentifier("browser.tabs")
        }
    }

    private func go() {
        guard let url = model.submitAddress() else { return }
        isAddressFocused = false
        store.load(url, in: model.selectedTab)
    }
}

struct BrowserTabsView: View {
    let model: BrowserModel
    let onClose: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.tabs) { tab in
                    Button {
                        model.select(tab.id)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: TLSpacing.xxs) {
                                if tab.title.isEmpty {
                                    Text(L10nKey.browserNewTab).font(.headline)
                                } else {
                                    Text(tab.title).font(.headline).lineLimit(1)
                                }
                                if let host = tab.url?.host() {
                                    Text(verbatim: host).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if tab.id == model.selectedTabID {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("browser.tabRow")
                    .swipeActions {
                        Button(role: .destructive) { close(tab.id) } label: {
                            TLLabel(.browserCloseTab, systemImage: "xmark")
                        }
                    }
                }
            }
            .navigationTitle(Text(L10nKey.browserTabs))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text(L10nKey.commonDone) }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.newTab()
                        dismiss()
                    } label: {
                        TLLabel(.browserNewTab, systemImage: "plus")
                    }
                    .disabled(model.tabs.count >= BrowserModel.maximumTabs)
                    .accessibilityIdentifier("browser.newTab")
                }
            }
        }
    }

    private func close(_ id: UUID) {
        model.closeTab(id)
        onClose(id)
    }
}

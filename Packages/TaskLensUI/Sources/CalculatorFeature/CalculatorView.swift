import SwiftUI
import TLCoreServices
import TLDesignSystem
import TLDomain
import TLLocalization
import TLNavigation
import UIKit

public struct CalculatorView: View {
    @State private var model: CalculatorModel
    @State private var showsHistory = false
    @State private var didCopy = false
    @Environment(AppRouter.self) private var router
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(model: CalculatorModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        VStack(spacing: TLSpacing.m) {
            Spacer(minLength: 0)
            displayArea
            keypad
        }
        .padding(TLSpacing.l)
        .navigationTitle(Text(L10nKey.workspaceToolCalculator))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showsHistory = true } label: {
                    TLLabel(.calculatorHistory, systemImage: "clock.arrow.circlepath")
                }
                .accessibilityIdentifier("calculator.history")
                Menu {
                    Button { copyResult() } label: { TLLabel(.calculatorCopyResult, systemImage: "doc.on.doc") }
                        .accessibilityIdentifier("calculator.copy")
                    if let text = model.resultText {
                        ShareLink(item: text) { TLLabel(.actionShare, systemImage: "square.and.arrow.up") }
                    }
                    Button { Task { await model.save() } } label: {
                        TLLabel(.commonSaveToSession, systemImage: "tray.and.arrow.down")
                    }
                    .accessibilityIdentifier("calculator.save")
                    Button {
                        if let text = model.resultText { router.push(.lensInput(text)) }
                    } label: {
                        TLLabel(.calculatorSendToActions, systemImage: "bolt")
                    }
                    .accessibilityIdentifier("calculator.sendToActions")
                } label: {
                    TLLabel(.commonMore, systemImage: "ellipsis.circle")
                }
                .disabled(model.result == nil)
                .accessibilityIdentifier("calculator.menu")
            }
        }
        .sheet(isPresented: $showsHistory) {
            CalculatorHistoryView(model: model)
        }
        .task { await model.load() }
        .sensoryFeedback(.success, trigger: model.savedItem?.id)
        .errorAlert(message: $model.errorMessage)
    }

    private var displayArea: some View {
        VStack(alignment: .trailing, spacing: TLSpacing.xs) {
            Text(verbatim: model.expression.isEmpty ? " " : model.expression)
                .font(.title3.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .accessibilityIdentifier("calculator.expression")
            Group {
                if let display = model.display {
                    Text(verbatim: display)
                } else {
                    Text(L10nKey.calculatorError)
                }
            }
            .font(.system(size: 64, weight: .light).monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.3)
            .accessibilityIdentifier("calculator.display")
            .accessibilityAddTraits(.updatesFrequently)
            .contextMenu {
                Button { copyResult() } label: { TLLabel(.calculatorCopyResult, systemImage: "doc.on.doc") }
            }
            if didCopy {
                Text(L10nKey.commonCopied).font(.caption).foregroundStyle(.secondary)
            } else if model.savedItem != nil {
                Label { Text(L10nKey.commonSaved) } icon: { Image(systemName: "checkmark.circle.fill") }
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        // Numbers and operators always read left to right, also in Arabic.
        .environment(\.layoutDirection, .leftToRight)
    }

    private var keypad: some View {
        Grid(horizontalSpacing: TLSpacing.s, verticalSpacing: TLSpacing.s) {
            GridRow {
                key(.clear, label: "AC", role: .function)
                key(.toggleSign, label: "±", role: .function)
                key(.percent, label: "%", role: .function)
                key(.op(.divide), label: "÷", role: .operator)
            }
            GridRow {
                digit(7); digit(8); digit(9)
                key(.op(.multiply), label: "×", role: .operator)
            }
            GridRow {
                digit(4); digit(5); digit(6)
                key(.op(.subtract), label: "−", role: .operator)
            }
            GridRow {
                digit(1); digit(2); digit(3)
                key(.op(.add), label: "+", role: .operator)
            }
            GridRow {
                digit(0)
                key(.decimalPoint, label: ".", role: .digit)
                key(.backspace, symbol: "delete.left", role: .function)
                key(.equals, label: "=", role: .operator)
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    private enum KeyRole { case digit, function, `operator` }

    private func digit(_ value: Int) -> some View {
        key(.digit(value), label: "\(value)", role: .digit)
    }

    private func key(_ key: CalculatorEngine.Key, label: String? = nil, symbol: String? = nil, role: KeyRole) -> some View {
        Button {
            Task { await model.press(key) }
        } label: {
            Group {
                if let symbol {
                    Image(systemName: symbol)
                } else {
                    Text(verbatim: label ?? "")
                }
            }
            .font(.title.weight(role == .digit ? .regular : .medium))
            .frame(maxWidth: .infinity, minHeight: 56)
            .foregroundStyle(role == .operator ? Color.white : Color.primary)
            .background(background(for: role), in: RoundedRectangle(cornerRadius: TLRadius.card, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: TLRadius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(for: key))
        .accessibilityIdentifier("calculator.key.\(identifier(for: key))")
    }

    private func background(for role: KeyRole) -> Color {
        switch role {
        case .digit: Color(.secondarySystemBackground)
        case .function: Color(.tertiarySystemFill)
        case .operator: .orange
        }
    }

    private func accessibilityLabel(for key: CalculatorEngine.Key) -> Text {
        switch key {
        case .digit(let value): Text(verbatim: "\(value)")
        case .decimalPoint: Text(L10nKey.calculatorKeyDecimal)
        case .op(.add): Text(L10nKey.calculatorKeyAdd)
        case .op(.subtract): Text(L10nKey.calculatorKeySubtract)
        case .op(.multiply): Text(L10nKey.calculatorKeyMultiply)
        case .op(.divide): Text(L10nKey.calculatorKeyDivide)
        case .equals: Text(L10nKey.calculatorKeyEquals)
        case .percent: Text(L10nKey.calculatorKeyPercent)
        case .toggleSign: Text(L10nKey.calculatorKeyToggleSign)
        case .clear: Text(L10nKey.calculatorKeyClear)
        case .backspace: Text(L10nKey.calculatorKeyBackspace)
        }
    }

    private func identifier(for key: CalculatorEngine.Key) -> String {
        switch key {
        case .digit(let value): "\(value)"
        case .decimalPoint: "decimal"
        case .op(let op):
            switch op {
            case .add: "add"
            case .subtract: "subtract"
            case .multiply: "multiply"
            case .divide: "divide"
            }
        case .equals: "equals"
        case .percent: "percent"
        case .toggleSign: "sign"
        case .clear: "clear"
        case .backspace: "backspace"
        }
    }

    private func copyResult() {
        guard let text = model.resultText else { return }
        UIPasteboard.general.string = text
        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            didCopy = false
        }
    }
}

struct CalculatorHistoryView: View {
    let model: CalculatorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if model.history.isEmpty {
                    Text(L10nKey.calculatorHistoryEmpty).foregroundStyle(.secondary)
                }
                ForEach(model.history) { record in
                    Button {
                        model.use(record)
                        dismiss()
                    } label: {
                        VStack(alignment: .trailing, spacing: TLSpacing.xxs) {
                            Text(verbatim: record.expression)
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(verbatim: "= " + CalculatorEngine.text(for: record.result))
                                .font(.title3.monospacedDigit())
                                .foregroundStyle(.primary)
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .environment(\.layoutDirection, .leftToRight)
                    }
                    .accessibilityHint(Text(L10nKey.calculatorUseResult))
                    .accessibilityIdentifier("calculator.historyRow")
                }
            }
            .navigationTitle(Text(L10nKey.calculatorHistory))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text(L10nKey.commonDone) }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button(role: .destructive) { Task { await model.clearHistory() } } label: {
                        Text(L10nKey.calculatorClearHistory)
                    }
                    .disabled(model.history.isEmpty)
                }
            }
        }
    }
}

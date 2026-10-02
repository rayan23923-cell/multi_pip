import SwiftUI
import TLDesignSystem
import TLLocalization
import UIKit

public struct SettingsView: View {
    /// Where data is stored, as shown to the user.
    public enum StorageDescription: Sendable {
        case appGroup
        case local
        case memory

        var key: L10nKey {
            switch self {
            case .appGroup: .settingsStorageAppGroup
            case .local: .settingsStorageLocal
            case .memory: .settingsStorageMemory
            }
        }
    }

    private let version: String
    private let storage: StorageDescription
    @Environment(\.openURL) private var openURL

    public init(version: String, storage: StorageDescription) {
        self.version = version
        self.storage = storage
    }

    public var body: some View {
        List {
            Section {
                Text(L10nKey.settingsPrivacyBody)
                    .font(.callout)
            } header: {
                Text(L10nKey.settingsPrivacy)
            }

            Section {
                Text(L10nKey.settingsLanguageBody)
                    .font(.callout)
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                } label: {
                    Text(L10nKey.settingsOpenSettings)
                }
            } header: {
                Text(L10nKey.settingsLanguage)
            }

            Section {
                LabeledContent {
                    Text(storage.key)
                } label: {
                    Text(L10nKey.settingsStorage)
                }
                LabeledContent {
                    Text(verbatim: version)
                } label: {
                    Text(L10nKey.settingsVersion)
                }
            } header: {
                Text(L10nKey.settingsAbout)
            }
        }
        .navigationTitle(Text(L10nKey.tabSettings))
    }
}

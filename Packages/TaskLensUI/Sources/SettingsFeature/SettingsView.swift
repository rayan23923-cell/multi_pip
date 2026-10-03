#if canImport(ActivityKit)
import ActivityKit
#endif
import AIFeature
import SwiftUI
import TLDesignSystem
import TLLocalization
#if DEBUG
import TLMediaUI
#endif
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
    private let ai: AISettingsModel?
    private let data: DataControlModel?
    @Environment(\.openURL) private var openURL

    public init(version: String, storage: StorageDescription, ai: AISettingsModel? = nil, data: DataControlModel? = nil) {
        self.version = version
        self.storage = storage
        self.ai = ai
        self.data = data
    }

    public var body: some View {
        List {
            Section {
                Text(L10nKey.settingsPrivacyBody)
                    .font(.callout)
            } header: {
                Text(L10nKey.settingsPrivacy)
            }

            if let ai {
                AISettingsSection(model: ai)
            }

            if let data {
                DataControlSection(model: data)
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
            } footer: {
                if !liveActivitiesEnabled {
                    Text(L10nKey.settingsLiveActivitiesOff)
                        .accessibilityIdentifier("settings.liveActivitiesOff")
                }
            }

            #if DEBUG
            // Developer tools; not in Release builds.
            Section {
                NavigationLink {
                    VideoPiPLabView()
                } label: {
                    Text(verbatim: "Video PiP Lab")
                }
                .accessibilityIdentifier("settings.videoPiPLab")
            } header: {
                Text(verbatim: "Developer")
            }
            #endif

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

    /// Session status on the Lock Screen needs Live Activities on for TaskLens.
    private var liveActivitiesEnabled: Bool {
        #if canImport(ActivityKit)
        ActivityAuthorizationInfo().areActivitiesEnabled
        #else
        true
        #endif
    }
}

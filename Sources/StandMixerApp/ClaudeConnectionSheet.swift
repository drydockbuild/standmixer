import SwiftUI
import StandMixerCore

struct ClaudeConnectionSheet: View {
    let presentationID: UUID
    @EnvironmentObject private var store: AppStore

    private func dismiss() { store.dismissClaudeConnection(presentationID: presentationID) }

    private var isPending: Bool { store.claudeConnectionActivity != nil }
    private var isConnected: Bool { store.claudeConnection?.state == .connected }
    private var needsSignIn: Bool { store.claudeConnection?.state == .signInRequired }
    private var isConfirmingLogout: Bool { store.showsClaudeLogoutConfirmation }
    private var heading: String {
        if isConfirmingLogout { return "Log out of Claude?" }
        switch store.claudeConnectionActivity {
        case .checking: return "Checking Claude Code…"
        case .connecting: return "Finish signing in in your browser"
        case .loggingOut: return "Logging out of Claude…"
        case nil:
            switch store.claudeConnection?.state {
            case .connected: return "Claude Code is connected"
            case .signInRequired: return "Sign in with Claude"
            case .missing: return "Claude Code is not installed"
            case .unavailable, nil: return "Couldn’t confirm the connection"
            }
        }
    }
    private var detail: String {
        if isConfirmingLogout {
            return "This signs out the shared Claude Code CLI profile. Other apps and workers using it may need to sign in again. Your StandMixer routing is preserved."
        }
        switch store.claudeConnectionActivity {
        case .checking: return "Looking for an existing Claude Code CLI sign-in."
        case .connecting: return "Claude’s official sign-in opens in your browser. This window will update when it finishes."
        case .loggingOut: return "Signing out through the official Claude Code CLI and checking that this profile is signed out."
        case nil: return store.claudeConnectionError ?? store.claudeConnection?.detail ?? "Recheck when you are ready."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 15) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Connect Claude for Codex").font(.system(size: 20, weight: .semibold))
                    Text("Let Codex launch Claude Code workers.")
                        .font(.system(size: 11)).foregroundStyle(StandMixerTheme.muted)
                }
                Spacer(minLength: 0)
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain).foregroundStyle(StandMixerTheme.muted)
                .accessibilityLabel("Close dialog")
            }
            .padding(22)
            Divider().overlay(StandMixerTheme.line)
            VStack(alignment: .leading, spacing: 15) {
                HStack(alignment: .top, spacing: 10) {
                    if isPending {
                        ProgressView().controlSize(.small).padding(.top, 2)
                    } else {
                        Image(systemName: isConnected && !isConfirmingLogout ? "checkmark.circle" : "info.circle")
                            .foregroundStyle(StandMixerTheme.accent).padding(.top, 2)
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        Text(heading).font(.system(size: 12, weight: .semibold))
                        Text(detail).font(.system(size: 11)).foregroundStyle(StandMixerTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 65, alignment: .topLeading)
                .accessibilityElement(children: .combine)
                if needsSignIn {
                    Text("Claude Desktop may use a different login. Continue to sign in to Claude Code through Claude’s official browser flow.")
                        .font(.system(size: 11)).foregroundStyle(StandMixerTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                } else if store.claudeConnection?.state == .missing {
                    Link("Claude Code setup instructions", destination: URL(string: "https://code.claude.com/docs/en/setup#install-claude-code")!)
                        .font(.system(size: 11))
                }
            }
            .padding(22)
            Divider().overlay(StandMixerTheme.line)
            HStack(spacing: 8) {
                if !isConfirmingLogout && store.canLogoutClaude {
                    Button("Log out…") { store.requestClaudeLogout(presentationID: presentationID) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11)).foregroundStyle(StandMixerTheme.muted)
                }
                Spacer()
                if isConfirmingLogout {
                    Button("Cancel") { store.cancelClaudeLogoutConfirmation(presentationID: presentationID) }
                        .buttonStyle(StandMixerSecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                    Button("Log out", role: .destructive) { store.logoutClaude(presentationID: presentationID) }
                        .buttonStyle(StandMixerPrimaryButtonStyle())
                } else if isConnected {
                    Button("Done", action: dismiss)
                        .buttonStyle(StandMixerPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                } else {
                    Button(store.claudeConnectionWasAutomatic && !isPending ? "Not now" : "Cancel", action: dismiss)
                        .buttonStyle(StandMixerSecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                    if !isPending {
                        if needsSignIn {
                            Button("Continue with Claude", action: store.connectClaude)
                                .buttonStyle(StandMixerPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                        } else {
                            Button("Recheck", action: store.checkClaudeConnection)
                                .buttonStyle(StandMixerPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                        }
                    }
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 15)
            .background(StandMixerTheme.surface.opacity(0.6))
        }
        .frame(width: 470)
        .background(StandMixerTheme.background).foregroundStyle(StandMixerTheme.ink)
        .onDisappear(perform: dismiss)
    }
}

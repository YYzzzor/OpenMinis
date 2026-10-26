//
//  ContentView+EmptyState.swift
//  Minis - 首页（Views/ContentView）
//
//  首次使用的空状态：设置步骤。
//
//  ContentView 文件地图见 ContentView/ContentView.swift。
//

import SwiftUI

extension ContentView {
    // MARK: - Empty State

    var emptyState: some View {
        let hasProviders = !providerStore.instances.isEmpty
        let hasGroups = !providerStore.modelGroups.isEmpty

        return VStack(spacing: 32) {
            Spacer()
            // App icon / hero
            Image(systemName: "sparkles")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .padding(.bottom, 4)

            VStack(spacing: 8) {
                Text("Welcome to MinisX")
                    .font(.title2.bold())
                Text("Your first On-Device Agent is almost ready.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Setup steps
            VStack(spacing: 16) {
                // Step 1 – Add Provider
                setupStep(
                    number: 1,
                    title: "Add a Provider",
                    subtitle: hasProviders ? "Done" : "Configure an API key or sign in with OAuth",
                    isDone: hasProviders
                ) {
                    if !hasProviders {
                        showAddProvider = true
                    }
                }

                // Step 2 – Select Models
                setupStep(
                    number: 2,
                    title: "Select Models",
                    subtitle: hasGroups ? "Done" : (hasProviders ? "Choose the models you want to use" : "Complete step 1 first"),
                    isDone: hasGroups
                ) {
                    if hasProviders && !hasGroups {
                        showSelectModels = true
                    }
                }

                // Step 3 – Start chatting
                setupStep(
                    number: 3,
                    title: "Start a Conversation",
                    subtitle: hasGroups ? "Tap the button below to begin" : "Complete step 2 first",
                    isDone: false
                ) {
                    if hasGroups {
                        openSession(Self.makeNewSessionId())
                    }
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: 400)
            Spacer()
        }
        .frame(maxHeight: .infinity)
        .padding(.horizontal, 32)
        .sheet(isPresented: $showAddProvider) {
            NavigationStack {
                AddProviderView()
            }
        }
        .sheet(isPresented: $showSelectModels) {
            NavigationStack {
                OnboardingModelSelectionView()
            }
        }
    }

    // title/subtitle must stay LocalizedStringKey, not String. A string literal at
    // the call site localizes fine on its own, but routing it through a String
    // parameter erases that: `Text(String)` stores the value verbatim and never
    // consults the string table, so these steps rendered English even though
    // Localizable.xcstrings has all 8 locales for these keys. Typing the parameter
    // as LocalizedStringKey keeps the literals (both branches of the `isDone`
    // ternaries included) resolving as keys.
    private func setupStep(
        number: Int,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        isDone: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                // Step indicator
                ZStack {
                    Circle()
                        .fill(isDone ? Color.green : Color.accentColor)
                        .frame(width: 32, height: 32)
                    if isDone {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                    } else {
                        Text("\(number)")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(isDone ? .secondary : .primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !isDone {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(UIColor.secondarySystemGroupedBackground))
            )
        }
        .buttonStyle(.plain)
        .disabled(isDone)
    }
}

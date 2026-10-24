import SwiftUI
import UIKit
import Lerix

struct ContentView: View {
    @State private var status = "Not requested"
    @State private var userId: String? = nil
    @State private var deviceId: String = ""
    @State private var notificationTokenId: String? = nil
    @State private var lastReceived = "none"
    @State private var lastTapped = "none"
    @State private var lastAction = ""

    var body: some View {
        NavigationView {
            Form {
                Section {
                    LabeledContent("Permission", value: status)
                    copyableRow(label: "User ID", value: userId)
                        .lerixConfidential()
                    copyableRow(label: "Device ID", value: deviceId)
                    copyableRow(label: "Notification Token ID", value: notificationTokenId)
                } header: {
                    Text("SDK state")
                } footer: {
                    Text("To send a test push from the dashboard, copy the Notification Token ID (not the User or Device ID) into its \"device tokens\" field — it only appears after notification permission is granted.")
                }

                Section("Notification events") {
                    LabeledContent("Last received (foreground)", value: lastReceived)
                    LabeledContent("Last tapped", value: lastTapped)
                }

                Section {
                    Button("Send feedback") {
                        Lerix.feedback.show { result in
                            lastAction = result.submitted
                                ? "Feedback sent (\(result.id ?? "queued"))"
                                : "Feedback cancelled"
                        }
                    }

                    Button("Show NPS survey (force)") {
                        Task {
                            let shown = await Lerix.surveys.maybeShowNps(force: true)
                            lastAction = shown ? "NPS shown" : "NPS not shown (no survey config?)"
                        }
                    }

                    Button("Track test event") {
                        Lerix.track("example_button_tapped", props: ["source": "example", "count": 1])
                        Lerix.analytics.flush()
                        lastAction = "Tracked example_button_tapped"
                    }
                } header: {
                    Text("Feedback, NPS, analytics")
                } footer: {
                    Text("Shake the device to report feedback too. The User ID row is masked in screenshots.")
                }

                Section {
                    ForEach(["checkout", "delivery", "help", "checkout-v2", "ios-hearts", "ios-numbers"], id: \.self) { key in
                        Button("Rate \"\(key)\" (force)") {
                            Task {
                                let shown = await Lerix.surveys.showRating(key, force: true, custom: ["source": "example"])
                                lastAction = shown ? "Rating \(key) shown" : "Rating \(key) not shown"
                            }
                        }
                    }
                    Button("Rate \"checkout-v2\" (if due)") {
                        Task {
                            let shown = await Lerix.surveys.showRating("checkout-v2")
                            lastAction = shown ? "Rating checkout-v2 shown (was due)" : "Rating checkout-v2 not due"
                        }
                    }
                    Button("Headless: rate \"delivery\" 4 + message") {
                        Task {
                            guard let prompt = await Lerix.surveys.dueRating("delivery", force: true, custom: ["source": "headless"]) else {
                                lastAction = "Headless: no prompt"
                                return
                            }
                            prompt.shown()
                            let bad = prompt.answer("nope")
                            let ok = prompt.answer(4, message: "Headless from iOS")
                            prompt.dismiss()
                            let group = prompt.groupOf(4)?.rawValue ?? "-"
                            lastAction = "Headless \(prompt.key ?? "") \(prompt.choices.count) choices: bad=\(bad) ok=\(ok) group=\(group)"
                        }
                    }
                    Button("Headless: NPS 3, then dismiss") {
                        Task {
                            guard let prompt = await Lerix.surveys.dueNps(force: true) else {
                                lastAction = "Headless NPS: no prompt"
                                return
                            }
                            let ok = prompt.answer(3)
                            prompt.dismiss()
                            lastAction = "Headless NPS ok=\(ok) group=\(prompt.groupOf(3)?.rawValue ?? "-") shape=\(prompt.appearance.shape ?? "-")"
                        }
                    }
                } header: {
                    Text("Surveys")
                }

                Section("Actions") {
                    Button("Request notification permission") {
                        Task {
                            let granted = await Lerix.notifications.requestPermissions()
                            status = granted ? "authorized" : "denied"
                            guard granted else { return }
                            for _ in 0..<10 where notificationTokenId == nil {
                                try? await Task.sleep(nanoseconds: 500_000_000)
                                refresh()
                            }
                        }
                    }

                    Button("Check permission status") {
                        Task {
                            let result = await Lerix.notifications.checkPermissionStatus()
                            status = result.rawValue
                        }
                    }

                    Button("Throw test error") {
                        Lerix.throwError(
                            "Example button tapped: simulated error",
                            stack: Thread.callStackSymbols,
                            type: .runtimeError,
                            severity: .low
                        )
                        lastAction = "Reported test error"
                    }

                    Button("Re-register user") {
                        Task {
                            try? await Lerix.reRegisterUser()
                            refresh()
                            lastAction = "Re-registered user"
                        }
                    }

                    Button("Trigger native crash", role: .destructive) {
                        // LerixCrashReporter persists this to disk
                        // synchronously and reports it automatically on the
                        // next launch — relaunch the app after this to see
                        // it show up as a reported error.
                        let array = [Int]()
                        _ = array[5]
                    }
                }

                if !lastAction.isEmpty {
                    Section("Last action") {
                        Text(lastAction)
                    }
                }
            }
            .navigationTitle("Lerix iOS Example")
            .lerixScreen("Home")
            .onAppear(perform: refresh)
            .task {
                Lerix.notifications.setOnNotificationReceived { payload in
                    Task { @MainActor in
                        lastReceived = describe(payload)
                    }
                }
                Lerix.notifications.setOnNotificationTapped { payload in
                    Task { @MainActor in
                        lastTapped = describe(payload)
                    }
                }

                // E2E: `SIMCTL_CHILD_LERIX_DEMO_SURVEY=delivery` (or `nps`) opens that survey at launch.
                if let demo = ProcessInfo.processInfo.environment["LERIX_DEMO_SURVEY"], !demo.isEmpty {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    let shown = demo == "nps"
                        ? await Lerix.surveys.maybeShowNps(force: true)
                        : await Lerix.surveys.showRating(demo, force: true, custom: ["source": "demo"])
                    lastAction = "Demo survey \(demo): \(shown ? "shown" : "not shown")"
                }

                for _ in 0..<10 where userId == nil {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    refresh()
                }
            }
        }
    }

    private func refresh() {
        userId = Lerix.getUserId()
        deviceId = Lerix.notifications.getDeviceId()
        notificationTokenId = Lerix.notifications.getRegisteredTokenId()
    }

    private func describe(_ payload: LerixNotificationPayload) -> String {
        "\(payload.title ?? "(no title)") — \(payload.body ?? "")"
    }

    @ViewBuilder
    private func copyableRow(label: String, value: String?) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value ?? "none")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let value {
                Button {
                    UIPasteboard.general.string = value
                    lastAction = "Copied \(label.lowercased())"
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

#Preview {
    ContentView()
}

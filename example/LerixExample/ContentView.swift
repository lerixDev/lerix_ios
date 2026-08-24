import SwiftUI
import UIKit
import Atelerix

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

                Section("Actions") {
                    Button("Request notification permission") {
                        Task {
                            let granted = await Atelerix.notifications.requestPermissions()
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
                            let result = await Atelerix.notifications.checkPermissionStatus()
                            status = result.rawValue
                        }
                    }

                    Button("Throw test error") {
                        Atelerix.throwError(
                            "Example button tapped: simulated error",
                            stack: Thread.callStackSymbols,
                            type: .runtimeError,
                            severity: .low
                        )
                        lastAction = "Reported test error"
                    }

                    Button("Re-register user") {
                        Task {
                            try? await Atelerix.reRegisterUser()
                            refresh()
                            lastAction = "Re-registered user"
                        }
                    }

                    Button("Trigger native crash", role: .destructive) {
                        // AtelerixCrashReporter persists this to disk
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
            .onAppear(perform: refresh)
            .task {
                Atelerix.notifications.setOnNotificationReceived { payload in
                    Task { @MainActor in
                        lastReceived = describe(payload)
                    }
                }
                Atelerix.notifications.setOnNotificationTapped { payload in
                    Task { @MainActor in
                        lastTapped = describe(payload)
                    }
                }

                for _ in 0..<10 where userId == nil {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    refresh()
                }
            }
        }
    }

    private func refresh() {
        userId = Atelerix.getUserId()
        deviceId = Atelerix.notifications.getDeviceId()
        notificationTokenId = Atelerix.notifications.getRegisteredTokenId()
    }

    private func describe(_ payload: AtelerixNotificationPayload) -> String {
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

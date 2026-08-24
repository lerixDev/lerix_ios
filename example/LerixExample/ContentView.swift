import SwiftUI
import UIKit
import Atelerix

struct ContentView: View {
    @State private var status = "Not requested"
    @State private var userId: String? = nil
    @State private var deviceId: String = ""
    @State private var lastAction = ""

    var body: some View {
        NavigationView {
            Form {
                Section("SDK state") {
                    LabeledContent("Permission", value: status)
                    copyableRow(label: "User ID", value: userId)
                    copyableRow(label: "Device ID", value: deviceId)
                }

                Section("Actions") {
                    Button("Request notification permission") {
                        Task {
                            let granted = await Atelerix.notifications.requestPermissions()
                            status = granted ? "authorized" : "denied"
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

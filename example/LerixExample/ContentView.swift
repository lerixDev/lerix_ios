import SwiftUI
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
                    LabeledContent("User ID", value: userId ?? "none")
                    LabeledContent("Device ID", value: deviceId)
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
        }
    }

    private func refresh() {
        userId = Atelerix.getUserId()
        deviceId = Atelerix.notifications.getDeviceId()
    }
}

#Preview {
    ContentView()
}

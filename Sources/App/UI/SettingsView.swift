import SwiftUI
import ImmichShared

struct SettingsView: View {
    @AppStorage("immichUrl") private var immichUrl = ""
    @AppStorage("apiKey") private var apiKey = ""
    @AppStorage("syncPictures") private var syncPictures = true
    @AppStorage("syncVideos") private var syncVideos = true
    @AppStorage("uploadScreenshots") private var uploadScreenshots = false
    @AppStorage("deleteLocal") private var deleteLocal = false
    
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    
    var body: some View {
        Form {
            Section("Server Connection") {
                TextField("Immich Instance URL", text: $immichUrl, prompt: Text("http://example.com:2283"))
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.URL)
                
                SecureField("API Key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                
                Button("Test Connection") {
                    Task {
                        // Create temporary client to test
                        let client = ImmichClient(baseURL: immichUrl, apiKey: apiKey)
                        do {
                            let success = try await client.validateConnection()
                            if success {
                                Log("Connection successful!", level: .info, category: "Settings")
                                await MainActor.run {
                                    alertTitle = "Connection Successful"
                                    alertMessage = "Successfully connected to Immich server!"
                                    showAlert = true
                                }
                            } else {
                                Log("Connection failed: Invalid response", level: .error, category: "Settings")
                                await MainActor.run {
                                    alertTitle = "Connection Failed"
                                    alertMessage = "Invalid response from server"
                                    showAlert = true
                                }
                            }
                        } catch {
                            Log("Connection failed: \(error.localizedDescription)", level: .error, category: "Settings")
                            await MainActor.run {
                                alertTitle = "Connection Failed"
                                alertMessage = error.localizedDescription
                                showAlert = true
                            }
                        }
                    }
                }
                .disabled(immichUrl.isEmpty || apiKey.isEmpty)
            }
            
            Section("Sync Options") {
                Toggle("Include Pictures", isOn: $syncPictures)
                Toggle("Include Videos", isOn: $syncVideos)
                Toggle("Include Screenshots", isOn: $uploadScreenshots)
            }
            
            Section("Danger Zone") {
                Toggle("Delete from iCloud after Upload", isOn: $deleteLocal)
                    .tint(.red)
                
                Button("Reset Database") {
                    // TODO: Reset DB
                }
                .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .padding()
        .alert(alertTitle, isPresented: $showAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
    }
}

#Preview {
    SettingsView()
}

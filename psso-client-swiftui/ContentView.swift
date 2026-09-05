import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 20) {
            // App Logo
            if let icon = NSImage(named: "AppLogo") ?? NSApplication.shared.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 96, height: 96)
                    .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
            }

            VStack(spacing: 8) {
                Text("Platform Single Sign-On")
                    .font(.title2.bold())
                    .foregroundColor(.primary)

                Text("This Application is meant for Local Account Management and Password Sync")
                    .font(.body)
                    .fontWeight(.medium)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 24)
                
                Text("DONOT DELETE THIS")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 24)
            }

            // Warning Notice Box
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 16))

                Text("System Requirement: Keep this application installed for identity sync.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
        }
        .padding(32)
        .frame(minWidth: 460, minHeight: 300)
    }
}

#Preview {
    ContentView()
}

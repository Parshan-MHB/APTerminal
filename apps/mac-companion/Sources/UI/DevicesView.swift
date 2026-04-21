import SwiftUI

struct DevicesView: View {
    @ObservedObject var model: MacCompanionAppModel

    var body: some View {
        List(model.trustedDevices, id: \.identity.id) { device in
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(device.identity.name).font(.headline)
                        Text(device.identity.platform.rawValue).font(.caption).foregroundStyle(.secondary)
                        Text(model.previewAccessSummary(for: device))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Trust expires \(device.expiresAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let lastSeenAt = device.lastSeenAt {
                            Text("Last seen \(lastSeenAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    Button("Revoke", role: .destructive) {
                        Task {
                            await model.revokeDevice(device.identity.id)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Preview Privilege")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Toggle(
                        "Allow full previews on Local Network",
                        isOn: Binding(
                            get: { model.previewAccessEnabled(for: device, mode: .lan) },
                            set: { enabled in
                                Task {
                                    await model.setPreviewAccess(enabled, for: device.identity.id, in: .lan)
                                }
                            }
                        )
                    )

                    Toggle(
                        "Allow full previews on Private Internet",
                        isOn: Binding(
                            get: { model.previewAccessEnabled(for: device, mode: .internetVPN) },
                            set: { enabled in
                                Task {
                                    await model.setPreviewAccess(enabled, for: device.identity.id, in: .internetVPN)
                                }
                            }
                        )
                    )

                    Text("Preview privilege is separate from pairing. Devices without it can still connect and use managed sessions, but they cannot see full Terminal or iTerm previews.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .toggleStyle(.switch)
                .padding(.top, 4)
            }
            .padding(.vertical, 6)
        }
        .overlay {
            if model.trustedDevices.isEmpty {
                ContentUnavailableView(
                    "No Trusted Devices",
                    systemImage: "iphone.slash",
                    description: Text("Pair an iPhone first, then grant preview privilege per device here.")
                )
            }
        }
        .navigationTitle("Devices")
    }
}

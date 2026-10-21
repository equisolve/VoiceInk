import SwiftUI

/// Explains that cloud services are off. Says "Managed by your organization" when a configuration profile sets the policy.
struct ManagedByOrganizationNotice: View {
    let message: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "building.2.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text(CloudPolicy.isManaged ? "Managed by your organization" : "Cloud services are turned off")
                    .font(.system(size: 13, weight: .semibold))

                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppMaterialCardBackground(cornerRadius: 10))
    }
}

/// A one-line form caption for places where cloud options are hidden.
struct ManagedByOrganizationCaption: View {
    /// Defaults to the cloud-services heading.
    var title: LocalizedStringKey?
    let message: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "building.2.fill")

            VStack(alignment: .leading, spacing: 2) {
                Text(title ?? (CloudPolicy.isManaged ? "Managed by your organization" : "Cloud services are turned off"))
                    .fontWeight(.semibold)
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// A read-only card for the AI endpoint an administrator configured through managed preferences.
struct ManagedAIProviderCard: View {
    let endpoint: ManagedAIEndpoint

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "building.2.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(endpoint.providerName)
                        .font(.system(size: 13, weight: .semibold))
                    Text(ManagedAIEndpoint.isManaged ? "Managed by your organization" : "Set in preferences")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                    GridRow {
                        Text("Model").foregroundStyle(.secondary)
                        Text(endpoint.model).textSelection(.enabled)
                    }
                    GridRow {
                        Text("Endpoint").foregroundStyle(.secondary)
                        Text(endpoint.baseURL.absoluteString).textSelection(.enabled)
                    }
                    GridRow {
                        Text("Token").foregroundStyle(.secondary)
                        Text(ManagedAIEndpoint.token().isEmpty ? "Not set" : "Set")
                    }
                }
                .font(.caption)

                Text(
                    ManagedAIEndpoint.isManaged
                        ? "Used for AI enhancement. These settings come from your organization and can't be changed here."
                        : "Used for AI enhancement. These settings come from the ManagedAI preference keys."
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppMaterialCardBackground(cornerRadius: 10))
    }
}

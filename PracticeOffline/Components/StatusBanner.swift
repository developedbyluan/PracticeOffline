import SwiftUI

/// Port of src/components/StatusBanner.tsx: a soft rounded notice above the favorites
/// list when it couldn't be refreshed.
struct StatusBanner: View {
    let kind: LoadProblem

    private var content: (icon: String, title: String, body: String) {
        switch kind {
        case .offline:
            ("wifi.slash", "You're offline.", "Downloaded lessons still play. Pull down to refresh.")
        case .failed:
            ("info.circle", "Couldn't update your favorites.", "Showing your last saved list. Pull down to try again.")
        }
    }

    var body: some View {
        let (icon, title, body) = content
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("\(Text(title).fontWeight(.semibold).foregroundStyle(.primary)) \(body)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    VStack {
        StatusBanner(kind: .offline)
        StatusBanner(kind: .failed)
    }
    .padding()
}

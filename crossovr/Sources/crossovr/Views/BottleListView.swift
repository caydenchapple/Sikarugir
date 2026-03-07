import SwiftUI

struct BottleListView: View {
    @EnvironmentObject private var bottleManager: BottleManager
    @Binding var selectedBottle: Bottle?

    @State private var searchText: String = ""
    @State private var showDeleteConfirm: Bool = false
    @State private var bottleToDelete: Bottle?
    @State private var deleteTitle: String = ""

    var filteredBottles: [Bottle] {
        if searchText.isEmpty { return bottleManager.bottles }
        return bottleManager.bottles.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        Group {
            if bottleManager.bottles.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search bottles")
        .navigationTitle("Bottles")
        .confirmationDialog(
            deleteTitle,
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let bottle = bottleToDelete {
                    try? bottleManager.deleteBottle(bottle)
                    if selectedBottle?.id == bottle.id { selectedBottle = nil }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete the bottle and all its data. This cannot be undone.")
        }
    }

    private var list: some View {
        List(filteredBottles, selection: $selectedBottle) { bottle in
            BottleRow(bottle: bottle)
                .tag(bottle)
                .contextMenu {
                    Button("Duplicate") {
                        try? bottleManager.duplicateBottle(bottle, newName: bottle.name + " Copy")
                    }
                    Divider()
                    Button("Delete", role: .destructive) {
                        bottleToDelete = bottle
                        deleteTitle = "Delete \"\(bottle.name)\"?"
                        showDeleteConfirm = true
                    }
                }
        }
        .listStyle(.sidebar)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "wineglass")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No Bottles")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Press ⇧⌘N to create your first bottle.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct BottleRow: View {
    let bottle: Bottle

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wineglass.fill")
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(bottle.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(bottle.backend.displayName)
                    Text("·")
                    Text(bottle.arch.rawValue)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

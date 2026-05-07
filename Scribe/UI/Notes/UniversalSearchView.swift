// Scribe/UI/Notes/UniversalSearchView.swift
import SwiftUI

struct UniversalSearchView: View {
    @StateObject private var vm = UniversalSearchViewModel()
    @Binding var isPresented: Bool
    var onNavigate: (MainSelection) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search notes, tasks, transcripts…", text: $vm.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .onSubmit { selectFirst() }
                if !vm.query.isEmpty {
                    Button { vm.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)

            Divider()

            if vm.sections.isEmpty {
                Text(vm.query.isEmpty ? "Start typing to search…" : "No results")
                    .foregroundStyle(.secondary)
                    .padding(32)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                        ForEach(vm.sections) { section in
                            Section {
                                ForEach(section.results) { result in
                                    Button {
                                        isPresented = false
                                        onNavigate(result.destination)
                                    } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: result.icon)
                                                .frame(width: 20)
                                                .foregroundStyle(.secondary)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(result.title).font(.body)
                                                if !result.snippet.isEmpty {
                                                    Text(result.snippet)
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                        .lineLimit(1)
                                                }
                                            }
                                            Spacer()
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 6)
                                    }
                                    .buttonStyle(.plain)
                                    Divider().padding(.leading, 46)
                                }
                            } header: {
                                Text(section.title)
                                    .font(.caption.bold())
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color(.windowBackgroundColor).opacity(0.95))
                            }
                        }
                    }
                }
                .frame(maxHeight: 400)
            }
        }
        .frame(width: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.2), radius: 20, y: 10)
        .onChange(of: vm.query) { _, _ in vm.scheduleSearch() }
        .onExitCommand { isPresented = false }
    }

    private func selectFirst() {
        guard let first = vm.sections.first?.results.first else { return }
        isPresented = false
        onNavigate(first.destination)
    }
}

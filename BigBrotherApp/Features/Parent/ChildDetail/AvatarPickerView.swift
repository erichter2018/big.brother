import SwiftUI
import PhotosUI
import BigBrotherCore

/// Wrapper that provides a local copy of the profile for editing.
struct AvatarPickerSheet: View {
    let child: ChildProfile
    let onSave: (ChildProfile) async -> Void
    @State private var editableProfile: ChildProfile

    init(child: ChildProfile, onSave: @escaping (ChildProfile) async -> Void) {
        self.child = child
        self.onSave = onSave
        self._editableProfile = State(initialValue: child)
    }

    var body: some View {
        AvatarPickerView(profile: editableProfile, onSave: onSave)
    }
}

/// Avatar picker: emoji + color palette + optional photo.
/// Saves to CloudKit via the child profile.
struct AvatarPickerView: View {
    let profile: ChildProfile
    let onSave: (ChildProfile) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedEmoji: String
    @State private var selectedColor: String
    @State private var photoItem: PhotosPickerItem?
    @State private var photoBase64: String?
    @State private var isSaving = false
    @State private var selectedTab = 0 // 0 = emoji, 1 = photo

    private static let colorPalette: [(String, Color)] = [
        ("#3B82F6", .blue),
        ("#8B5CF6", .purple),
        ("#EC4899", .pink),
        ("#EF4444", .red),
        ("#F97316", .orange),
        ("#EAB308", .yellow),
        ("#22C55E", .green),
        ("#14B8A6", .teal),
        ("#06B6D4", .cyan),
        ("#6366F1", .indigo),
        ("#A855F7", Color(red: 0.66, green: 0.33, blue: 0.97)),
        ("#64748B", .gray),
    ]

    private static let emojiSections: [(String, [String])] = [
        ("Animals", ["🦊", "🐱", "🐶", "🐼", "🦁", "🐸", "🐙", "🦄", "🐝", "🦋", "🐬", "🦈", "🐢", "🐧", "🦉", "🐨"]),
        ("Faces", ["😎", "🤩", "😇", "🥳", "😜", "🤗", "😺", "👻", "🤖", "👽", "💀", "🎃"]),
        ("Sports", ["⚽", "🏀", "🏈", "⚾", "🎾", "🏐", "🎳", "🏓", "🥊", "🏄", "🎿", "🚴"]),
        ("Nature", ["🌸", "🌻", "🌈", "⭐", "🔥", "❄️", "🌊", "🍀", "🌙", "☀️", "🌺", "🍁"]),
        ("Objects", ["🎸", "🎮", "🎨", "📚", "🔮", "💎", "🎭", "🎪", "🚀", "🏰", "🎵", "🎯"]),
    ]

    init(profile: ChildProfile, onSave: @escaping (ChildProfile) async -> Void) {
        self.profile = profile
        self.onSave = onSave
        self._selectedEmoji = State(initialValue: profile.avatarEmoji ?? "🦊")
        self._selectedColor = State(initialValue: profile.avatarColor ?? "#3B82F6")
        self._photoBase64 = State(initialValue: profile.avatarPhotoBase64)
        self._selectedTab = State(initialValue: profile.avatarPhotoBase64 != nil ? 1 : 0)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Preview
                    avatarPreview
                        .padding(.top, 16)

                    // Tab: Emoji vs Photo
                    Picker("Avatar Type", selection: $selectedTab) {
                        Text("Emoji").tag(0)
                        Text("Photo").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)

                    if selectedTab == 0 {
                        emojiPicker
                    } else {
                        photoPicker
                    }

                    // Color palette (shared)
                    colorPalettePicker
                }
                .padding(.bottom, 32)
            }
            .navigationTitle("Choose Avatar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(isSaving)
                }
            }
        }
    }

    // MARK: - Preview

    @ViewBuilder
    private var avatarPreview: some View {
        let bgColor = Color(hex: selectedColor) ?? .blue
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [bgColor, bgColor.opacity(0.7)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 100, height: 100)

            if selectedTab == 1, let base64 = photoBase64,
               let data = Data(base64Encoded: base64),
               let img = UIImage(data: data) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 100, height: 100)
                    .clipShape(Circle())
            } else {
                Text(selectedEmoji)
                    .font(.system(size: 50))
            }
        }
        .shadow(color: bgColor.opacity(0.5), radius: 12)
    }

    // MARK: - Emoji Picker

    private var emojiPicker: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Self.emojiSections, id: \.0) { section in
                VStack(alignment: .leading, spacing: 8) {
                    Text(section.0)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 8), spacing: 8) {
                        ForEach(section.1, id: \.self) { emoji in
                            Button {
                                selectedEmoji = emoji
                            } label: {
                                Text(emoji)
                                    .font(.system(size: 28))
                                    .frame(width: 40, height: 40)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(selectedEmoji == emoji ? Color.accentColor.opacity(0.2) : .clear)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(selectedEmoji == emoji ? Color.accentColor : .clear, lineWidth: 2)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    // MARK: - Photo Picker

    private var photoPicker: some View {
        VStack(spacing: 16) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("Choose Photo", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal)
            .onChange(of: photoItem) { _, item in
                Task { await loadPhoto(item) }
            }

            if photoBase64 != nil {
                Button(role: .destructive) {
                    photoBase64 = nil
                    selectedTab = 0
                } label: {
                    Label("Remove Photo", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - Color Palette

    private var colorPalettePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Color")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                ForEach(Self.colorPalette, id: \.0) { hex, color in
                    Button {
                        selectedColor = hex
                    } label: {
                        Circle()
                            .fill(color)
                            .frame(width: 40, height: 40)
                            .overlay(
                                Circle()
                                    .stroke(.white, lineWidth: selectedColor == hex ? 3 : 0)
                            )
                            .overlay(
                                Circle()
                                    .stroke(Color.accentColor, lineWidth: selectedColor == hex ? 2 : 0)
                                    .padding(1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }

    // MARK: - Actions

    private func loadPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }

        // Resize to max 200x200 to keep CloudKit storage small
        guard let original = UIImage(data: data) else { return }
        let size = CGSize(width: 200, height: 200)
        let renderer = UIGraphicsImageRenderer(size: size)
        let resized = renderer.image { _ in
            original.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpeg = resized.jpegData(compressionQuality: 0.7) else { return }
        photoBase64 = jpeg.base64EncodedString()
    }

    private func save() async {
        isSaving = true
        var updated = profile
        updated.avatarColor = selectedColor
        if selectedTab == 0 {
            updated.avatarEmoji = selectedEmoji
            updated.avatarPhotoBase64 = nil
        } else if let photo = photoBase64 {
            updated.avatarPhotoBase64 = photo
            updated.avatarEmoji = nil
        }
        updated.updatedAt = Date()
        await onSave(updated)
        isSaving = false
        dismiss()
    }
}

import SwiftUI
import MapKit
import BigBrotherCore

/// Editor for adding/editing a named place (school, friends, etc.).
/// Shows a map with a draggable pin, name field, radius slider, and child selector.
struct NamedPlaceEditorView: View {
    let appState: AppState
    var existingPlace: NamedPlace?
    let onSave: (NamedPlace) async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var coordinate: CLLocationCoordinate2D = CLLocationCoordinate2D(latitude: 40.508, longitude: -79.861)
    @State private var radiusMeters: Double = 150
    @State private var selectedChildIDs: Set<ChildProfileID> = []
    @State private var position: MapCameraPosition = .automatic
    @State private var isSaving = false
    @State private var searchText = ""

    init(appState: AppState, existingPlace: NamedPlace? = nil, onSave: @escaping (NamedPlace) async -> Void) {
        self.appState = appState
        self.existingPlace = existingPlace
        self.onSave = onSave
        if let place = existingPlace {
            _name = State(initialValue: place.name)
            _coordinate = State(initialValue: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude))
            _radiusMeters = State(initialValue: place.radiusMeters)
            _selectedChildIDs = State(initialValue: Set(place.childProfileIDs))
            _notifyArrival = State(initialValue: place.notifyArrival)
            _notifyDeparture = State(initialValue: place.notifyDeparture)
        }
    }

    @State private var notifyArrival: Bool = true
    @State private var notifyDeparture: Bool = true

    var body: some View {
        NavigationStack {
            Form {
                // Map with pin
                Section {
                    Map(position: $position, interactionModes: .all) {
                        Annotation(name.isEmpty ? "New Place" : name, coordinate: coordinate) {
                            ZStack {
                                Circle()
                                    .fill(.blue.opacity(0.15))
                                    .frame(width: radiusCircleSize, height: radiusCircleSize)
                                Image(systemName: "mappin.circle.fill")
                                    .font(.title)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                    .frame(height: 250)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .onTapGesture { location in
                        // Note: Map tap-to-move-pin requires MapReader in iOS 17+
                    }

                    // Search for address
                    HStack {
                        TextField("Search address...", text: $searchText)
                            .textFieldStyle(.roundedBorder)
                        Button("Go") {
                            Task { await searchAddress() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(searchText.isEmpty)
                    }

                    // Manual coordinate display
                    Text(String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Name
                Section("Place Name") {
                    TextField("e.g. School, Grandma's House", text: $name)
                }

                // Radius
                Section("Radius: \(Int(radiusMeters))m") {
                    Slider(value: $radiusMeters, in: 50...500, step: 25)
                }

                // Children
                Section("Applies To") {
                    if selectedChildIDs.isEmpty {
                        Text("All children")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(appState.childProfiles) { profile in
                        Toggle(profile.name, isOn: Binding(
                            get: { selectedChildIDs.contains(profile.id) },
                            set: { enabled in
                                if enabled { selectedChildIDs.insert(profile.id) }
                                else { selectedChildIDs.remove(profile.id) }
                            }
                        ))
                    }
                    if !selectedChildIDs.isEmpty {
                        Button("Apply to all children") {
                            selectedChildIDs = []
                        }
                        .font(.caption)
                    }
                }

                Section("Notifications") {
                    Toggle("Notify on arrival", isOn: $notifyArrival)
                    Toggle("Notify on departure", isOn: $notifyDeparture)
                }
            }
            .navigationTitle(existingPlace == nil ? "New Place" : "Edit Place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(name.isEmpty || isSaving)
                }
            }
            .task {
                if existingPlace != nil {
                    position = .camera(MapCamera(
                        centerCoordinate: coordinate, distance: 2000
                    ))
                } else if let home = homeCoordinate {
                    coordinate = home
                    position = .camera(MapCamera(centerCoordinate: home, distance: 5000))
                }
            }
        }
    }

    // MARK: - Helpers

    private var radiusCircleSize: CGFloat {
        // Approximate visual radius on the map (rough scaling)
        max(30, CGFloat(radiusMeters) / 5)
    }

    private var homeCoordinate: CLLocationCoordinate2D? {
        for device in appState.childDevices {
            let latKey = "homeLatitude.\(device.id.rawValue)"
            let lonKey = "homeLongitude.\(device.id.rawValue)"
            if let lat = UserDefaults.standard.object(forKey: latKey) as? Double,
               let lon = UserDefaults.standard.object(forKey: lonKey) as? Double {
                return CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
        }
        return nil
    }

    private func searchAddress() async {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = searchText
        if let home = homeCoordinate {
            request.region = MKCoordinateRegion(
                center: home, latitudinalMeters: 50000, longitudinalMeters: 50000
            )
        }
        do {
            let response = try await MKLocalSearch(request: request).start()
            if let item = response.mapItems.first {
                coordinate = item.placemark.coordinate
                position = .camera(MapCamera(centerCoordinate: coordinate, distance: 2000))
                if name.isEmpty, let itemName = item.name {
                    name = itemName
                }
            }
        } catch {
            #if DEBUG
            print("[NamedPlace] Search failed: \(error.localizedDescription)")
            #endif
        }
    }

    private func save() async {
        isSaving = true
        guard let familyID = appState.parentState?.familyID else {
            isSaving = false
            return
        }

        let place = NamedPlace(
            id: existingPlace?.id ?? UUID(),
            familyID: familyID,
            name: name,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            radiusMeters: radiusMeters,
            createdAt: existingPlace?.createdAt ?? Date(),
            createdBy: "Parent",
            childProfileIDs: selectedChildIDs.isEmpty ? [] : Array(selectedChildIDs),
            notifyArrival: notifyArrival,
            notifyDeparture: notifyDeparture
        )

        await onSave(place)
        isSaving = false
        dismiss()
    }
}

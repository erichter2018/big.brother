import SwiftUI
import MapKit
import BigBrotherCore

/// Compact map card showing child's last known location.
/// Tap navigates to full LocationMapView.
struct MiniMapCard: View {
    let latitude: Double
    let longitude: Double
    let address: String?
    let timestamp: Date?
    let isAtHome: Bool
    let homeCoordinate: CLLocationCoordinate2D?
    var isDriving: Bool = false
    var speedMph: Int? = nil

    var body: some View {
        ZStack(alignment: .bottom) {
            Map(initialPosition: mapPosition) {
                Annotation("", coordinate: coordinate) {
                    Image(systemName: "figure.stand")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(Circle().fill(.blue))
                        .shadow(radius: 3)
                }
                if let home = homeCoordinate {
                    Annotation("Home", coordinate: home) {
                        Image(systemName: "house.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .allowsHitTesting(false)
            .frame(height: 150)

            // Overlay bar
            HStack(spacing: 6) {
                if isDriving {
                    Label(speedMph != nil ? "Driving \(speedMph!) mph" : "Driving", systemImage: "car.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                } else if let speedMph, speedMph > 2 {
                    Label("Moving", systemImage: "figure.walk")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.blue)
                } else if isAtHome {
                    Label("Home", systemImage: "house.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                } else if let address {
                    Image(systemName: "location.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.blue)
                    Text(address)
                        .font(.caption2)
                        .lineLimit(1)
                }
                Spacer()
                if let timestamp {
                    Text(timestamp, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    + Text(" ago")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
    }

    private var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    private var mapPosition: MapCameraPosition {
        .region(MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
        ))
    }
}

/// Placeholder when no location data is available.
struct MiniMapPlaceholder: View {
    var body: some View {
        HStack {
            Image(systemName: "location.slash")
                .foregroundStyle(.secondary)
            Text("Location unavailable")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(12)
        .frame(height: 60)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

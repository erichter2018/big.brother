# Big.Brother — Project Instructions

## What This Is
iOS + iPadOS parental-control app for a family of 8 (2 parents, 6 children).
Single SwiftUI binary with parent mode and child mode.
See ARCHITECTURE.md for the full Phase 1 design.

## Key Rules
- Target iOS 17.0+
- Use SwiftUI + @Observable (no Combine unless necessary)
- Shared code goes in BigBrotherCore (local Swift Package) — keep it pure Swift + Foundation
- FamilyControls/ManagedSettings/DeviceActivity imports belong ONLY in app target and extension targets
- All App Group file writes must be atomic (write temp file, rename)
- Never store secrets in CloudKit or UserDefaults — use Keychain
- Never store PIN in plaintext anywhere

## Project Structure
- BigBrotherCore/ — local Swift Package, shared models + logic
- BigBrotherApp/ — main app target
- BigBrotherMonitor/ — DeviceActivityMonitor extension
- BigBrotherShield/ — ShieldConfiguration extension
- BigBrotherShieldAction/ — ShieldAction extension

## Identifiers
- App Group: group.fr.bigbrother.shared
- CloudKit: iCloud.fr.bigbrother.app
- Bundle: fr.bigbrother.app
- Keychain group: $(AppIdentifierPrefix)fr.bigbrother.shared

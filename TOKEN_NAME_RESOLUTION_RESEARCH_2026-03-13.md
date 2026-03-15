# Token Name Resolution Research - 2026-03-13

This note supplements `TOKEN_NAME_RESOLUTION.md` with current public Apple guidance and a recommended product direction.

## Bottom line

There is no supported App Store-safe way, as of March 13, 2026, to extract real app names inside a `DeviceActivityReport` extension and move them back into the host app automatically.

That is not an accidental limitation. It is the intended privacy model of Screen Time:

- `FamilyActivityPicker` deliberately returns opaque values rather than raw bundle IDs or names.
- `DeviceActivityReport` is intentionally sandboxed so sensitive usage data cannot leave the extension process.
- Apple DTS has explicitly said this includes blocking shared `UserDefaults`, network access, and similar outbound channels on real devices.

The practical conclusion is:

1. Stop treating automatic token -> name extraction from `DeviceActivityReport` as a solvable engineering problem.
2. Move to user-mediated identity reveal flows built around `FamilyActivityPicker`.
3. Keep token bytes opaque across CloudKit and only resolve human labels on the child device, with parent-visible aliases synced separately.

## What Apple publicly says

### 1. Tokens are intentionally opaque

Apple's `FamilyActivityPicker` documentation says the system uses opaque values to represent the selection "to protect the user's privacy."

Implication:

- Opaqueness is the design, not a missing helper API.
- If you need an app identity outside a privileged Screen Time UI, Apple expects the user to explicitly choose it in a sanctioned picker flow.

Source:

- https://developer.apple.com/documentation/familycontrols/familyactivitypicker

### 2. Token display is supported, token introspection is not

Apple's "Displaying Activity Labels" docs describe `Label(token)` and related views as a read-only visual representation of an application, category, or domain.

Implication:

- Apple gives you a rendering primitive.
- Apple does not give you a supported text extraction primitive.
- Trying to convert a rendered token label into text via view inspection, screenshots, OCR, or accessibility is fighting the framework.

Source:

- https://developer.apple.com/documentation/familycontrols/displayingactivitylabels

### 3. Screen Time is privacy-first by design

In WWDC21 "Meet the Screen Time API," Apple states that usage data is intended to remain invisible outside the user's device, and that Family Controls uses opaque tokens so outsiders do not learn which apps and sites are being used.

In WWDC22 "What's new in Screen Time API," Apple reiterates that the API remains privacy-preserving and that Device Activity report UI was introduced as privacy-preserving UI.

Implication:

- The product architecture must assume that raw activity identity is intentionally difficult or impossible to export.

Sources:

- https://developer.apple.com/videos/play/wwdc2021/10123/
- https://developer.apple.com/videos/play/wwdc2022/110336/

### 4. Apple DTS explicitly confirmed the extension leak-prevention model

Apple DTS said, regarding Device Activity extensions on real devices:

- data written to `UserDefaults` is not dropped, but
- it is intentionally not propagated back to the app when that would leak sensitive usage data
- the sandbox prevents passing sensitive user information out of the extension
- this includes shared user defaults and network access
- simulator behavior is not representative here

Implication:

- The current attempts in `TOKEN_NAME_RESOLUTION.md` are aligned with known blocked paths.
- If Keychain or some other side channel appears to work intermittently, it should be treated as unsupported and patch-risky.

Source:

- https://developer.apple.com/forums/thread/728044

### 5. DeviceActivityReport is rendered out of process

Apple Developer Forums discussions around report view sizing/background behavior note that these views are rendered out of process.

Implication:

- This matches your failed capture attempts.
- Programmatic screenshot or hierarchy tricks should be treated as unreliable even if you can sometimes get pixels.

Source:

- https://developer.apple.com/forums/thread/742471

## What this means for the current codebase

The codebase is already converging on the right conclusion.

Relevant local findings:

- `BigBrotherActivityReport/BigBrotherActivityReportExtension.swift`
- `BigBrotherApp/Features/Child/ChildHomeView.swift`
- `BigBrotherApp/Features/Child/ChildHomeViewModel.swift`
- `BigBrotherShieldAction/BigBrotherShieldActionExtension.swift`

The app is currently trying multiple bridges:

- file writes
- shared defaults
- keychain
- `openURL`
- QR rendering + screenshot + Vision decode
- local OCR of `Label(token)`

Those are useful experiments, but they should now be classified as:

- supported: none
- unsupported and likely to break: Keychain, visual capture, any exfiltration path from report extension
- architecturally valid: explicit user selection via `FamilyActivityPicker`

## Most promising concrete fix in this codebase

There is one high-value path that looks underused in the current code:

- `FamilyActivityPicker` updates a `FamilyActivitySelection`
- Apple's docs explicitly show `selection.applications`, `selection.categories`, and `selection.webDomains`
- `selection.applications` is a set of `Application` instances selected by the user

That matters because the current code often does this:

- take `selection.applicationTokens`
- later reconstruct `Application(token: token)`
- then attempt to read `localizedDisplayName` or `bundleIdentifier`

If the metadata is only available in the picker-authorized `Application` objects, then reconstructing from token later discards the useful part.

Practical implication:

- in picker flows, iterate `selection.applications`, not only `selection.applicationTokens`
- immediately persist:
  - token bytes
  - localized display name
  - bundle identifier
  - your own stable alias

This does not solve `DeviceActivityReport` exfiltration. But it likely solves the most important app/product path: exact app identification after an explicit picker choice.

Relevant Apple doc signal:

- `FamilyActivityPicker` examples explicitly access `selection.applications`
- `FamilyActivitySelection.categories` is documented as "A set of category instances selected by the user," strongly implying the same contract for applications

Sources:

- https://developer.apple.com/documentation/familycontrols/familyactivitypicker
- https://developer.apple.com/documentation/familycontrols/familyactivityselection/categories

Relevant local files:

- `/Users/erichter/Desktop/big.brother.fr.nosync/BigBrotherApp/Features/Child/UnlockRequestPickerView.swift`
- `/Users/erichter/Desktop/big.brother.fr.nosync/BigBrotherApp/Services/Enforcement/AppBlockingStore.swift`

## Recommended architecture

### Recommendation A: Make the picker the official identity bridge

Use `FamilyActivityPicker` anywhere the system should reveal an app's identity to your app.

Concrete design:

1. Child hits a category shield and taps "Ask for More Time".
2. `ShieldAction` writes only an "unlock request pending" breadcrumb.
3. Main app opens a focused picker flow on the child device:
   "Select the app you were trying to open."
4. The child explicitly selects the app in `FamilyActivityPicker`.
5. Store:
   - opaque token bytes for enforcement on that same child device
   - `localizedDisplayName` and `bundleIdentifier` from `selection.applications` when available
   - a human alias for parent UI
   - request metadata
6. Sync only the alias plus opaque token blob to CloudKit.
7. Parent approves by request ID; child uses the original opaque token blob locally.

Why this is the best fit:

- It uses the one Apple-sanctioned crossing point where user intent is explicit.
- It removes dependence on hidden or brittle channels.
- It already matches part of your existing unlock request flow.

### Recommendation B: Build an explicit "App Catalog" step on the child device

If the parent experience needs good names before the first unlock request, add a child-device onboarding or maintenance flow:

- "Review apps installed on this device"
- present `FamilyActivityPicker`
- let parent/child select common apps in batches
- save token -> alias mapping locally

This gives you a growing local catalog of known apps without needing to scrape `DeviceActivityReport`.

Important detail:

- The alias is the source of truth for cross-device UI.
- The token remains the source of truth for local enforcement.

### Recommendation C: Treat parent and child data differently

On the child device:

- Keep opaque token bytes for enforcement.
- Render `Label(token)` locally when possible.
- Maintain a local alias cache populated only from explicit picker selections.

On the parent device:

- Never depend on being able to decode or render the child's token.
- Show the synced alias and request metadata.
- Send approvals back by request ID and opaque token payload.

This matches Apple's privacy model much better than trying to make the parent understand the token directly.

## Product changes that follow from this

### 1. Reframe the parent UX

Instead of promising "we always know the exact app immediately," promise one of:

- "Child requested access to TikTok"
- or, before identification, "Child requested access to an app"

Then complete identification through the picker flow.

This is less magical, but it is reliable and shippable.

### 2. Reframe the child UX

After a blocked launch:

- immediately deep-link to a clean in-app request flow
- auto-open the picker
- explain that the app can only send the exact app name after the child explicitly selects it

This is a privacy-consistent explanation and easier to maintain than hidden background tricks.

### 3. Use the report extension only for display

Keep `DeviceActivityReport` for:

- showing local activity summaries
- building a nice child-facing dashboard
- diagnostics

Do not use it as a data transport mechanism.

## Alternatives and why they are weaker

### Alternative 1: Keep pushing on Keychain / App Group escape hatches

Not recommended.

Reason:

- Apple DTS already stated the sandbox is intended to block outbound data leakage.
- If any side channel works today, it is likely an implementation hole rather than a contract.
- Shipping core UX on top of that creates a large regression risk in any iOS update.

### Alternative 2: OCR or screenshot the report output

Not recommended.

Reason:

- report rendering is out of process
- your own experiments already hit privacy overlays
- even partial success would be fragile, slow, and likely App Review-hostile

### Alternative 3: Infer the current app from recent activity data

Not recommended.

Reason:

- Device Activity reporting is aggregated, delayed, and privacy-shaped
- it is not a reliable real-time "currently blocked app" signal
- false positives would be bad for a parental control app

### Alternative 4: Use MDM / supervision

Technically viable in a different product category, but not for this app as currently conceived.

Apple's Device Management APIs can provide installed-app inventory to an MDM server, and managed app APIs expose app identifiers and names in managed contexts.

Reason this does not fit:

- that is an MDM architecture, not a normal App Store parental control app architecture
- it typically depends on enrollment, supervision, or organizational management workflows
- it is a completely different product/distribution model

Sources:

- https://developer.apple.com/documentation/devicemanagement/managed-application-attributes-command
- https://developer.apple.com/forums/topics/business-and-education-topic/business-and-education-topic-device-management

## Recommended next implementation steps

1. Remove "automatic resolution" as a product requirement.
2. Keep token blobs opaque end-to-end.
3. Promote the existing unlock-picker path into the primary exact-app identification flow.
4. Add a first-run "Build Your Child's App Catalog" flow on the child device.
5. Persist `tokenData -> alias` locally on child.
6. Sync aliases, request IDs, and raw token blobs to CloudKit.
7. Simplify or delete the experimental report-extension bridge code after validating the picker-first UX.

## Clear recommendation

The most feasible solution is not a lower-level hack. It is a product-level pivot:

- `DeviceActivityReport` stays display-only.
- `FamilyActivityPicker` becomes the only trusted app-identity export path.
- Parent-facing names come from child-device explicit selections, not from report-extension extraction.

That is the solution most aligned with Apple's public privacy model and the one least likely to break under future iOS releases.

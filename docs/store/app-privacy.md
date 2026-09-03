# App Privacy questionnaire

These answers must match `Resources/PrivacyInfo.xcprivacy` exactly — App Store
Connect cross-checks the manifest at upload. The manifest declares two collected
data types and two accessed-API categories; nothing else is collected.

## Does this app collect data?  **Yes**

Apple's definition of "collect" is "transmitted off the device". Aria transmits
search text and library metadata to the server the user configured. That server
is the user's own; the developer never receives it. The questionnaire has no way
to say that, so it is stated in the privacy policy and the review notes instead.

## Data types

### Search History
- **Collected:** Yes
- **Used for:** App Functionality
- **Linked to the user's identity:** No
- **Used for tracking:** No

### Product Interaction
- **Collected:** Yes
- **Used for:** App Functionality
- **Linked to the user's identity:** No
- **Used for tracking:** No

(Product Interaction covers library metadata — titles, artists, albums, play
history — synced to the user's own server for "Ask Your Library".)

## Every other category: **Not collected**

Contact info, health, financial, location, sensitive info, contacts, user
content beyond the above, browsing history, identifiers, purchases (Apple
handles the IAP; the app sees only an entitlement), usage data, diagnostics,
other data — all **No**.

## Tracking

**Does this app use data for tracking?  No.** There is no advertising SDK, no
analytics SDK, no third-party SDK of any kind (the project has zero
dependencies), and no `NSUserTrackingUsageDescription`.

## Required-reason APIs (already in the manifest)

| API | Reason code | Why |
|---|---|---|
| UserDefaults | CA92.1 | app's own settings |
| File timestamp | C617.1 | detecting changed/missing library files |

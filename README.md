# OpenWearablesHealthCore

A standalone Swift package for syncing Apple HealthKit data to the [Open Wearables](https://github.com/the-momentum/open-wearables) platform.

## Background

This package extracts the native iOS sync engine from the [Flutter SDK](https://github.com/the-momentum/open_wearables_health_sdk) into a standalone Swift Package with no Flutter dependencies.

The goal is to create a shared native iOS library that both the Flutter and a future React Native SDK can depend on — similar to how [Vital](https://github.com/tryVital) structures their platform SDKs with shared native cores (`vital-ios`, `vital-android`) and thin cross-platform wrappers (`vital-react-native`, `vital-flutter`).

### Current state

```
open_wearables_health_sdk (Flutter)
└── ios/Classes/   ← Swift code embedded directly in the Flutter plugin
```

### Target architecture

```
open-wearables-ios (this package)        ← shared native core
├── Flutter SDK wrapper (method channels)
└── React Native SDK wrapper (bridge)
```

Once this shared core is stable, both cross-platform SDKs will depend on it via Swift Package Manager or CocoaPods instead of each maintaining their own copy of the sync engine.

## What it does

- Syncs 40+ Apple HealthKit data types to the Open Wearables platform
- Background sync via HealthKit observer queries and BGTaskScheduler
- Incremental updates using anchored queries (only syncs new data)
- Resumable sync sessions that survive app termination
- Chunked streaming uploads with automatic retry via a local outbox
- Secure credential storage in iOS Keychain
- Network monitoring with automatic resume on connectivity restored
- Token refresh support

## Installation

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/sundsdal/open-wearables-ios.git", from: "0.1.0")
]
```

### CocoaPods

```ruby
pod 'OpenWearablesHealthCore', :git => 'https://github.com/sundsdal/open-wearables-ios.git'
```

## Usage

```swift
import OpenWearablesHealthCore

// Configure
OWHSyncEngine.shared.configure(baseUrl: "https://api.openwearables.io")

// Sign in (credentials come from your backend)
OWHSyncEngine.shared.signIn(
    userId: "usr_abc123",
    accessToken: "at_..."
)

// Request HealthKit permissions
OWHSyncEngine.shared.requestAuthorization(types: ["steps", "heartRate", "sleep", "workout"]) { success in
    guard success else { return }

    // Start background sync
    OWHSyncEngine.shared.startBackgroundSync()
}
```

## Supported data types

| Category | Types |
|----------|-------|
| Activity | steps, distanceWalkingRunning, distanceCycling, flightsClimbed, walkingSpeed, walkingStepLength, walkingAsymmetryPercentage, walkingDoubleSupportPercentage, sixMinuteWalkTestDistance |
| Energy | activeEnergy, basalEnergy |
| Heart | heartRate, restingHeartRate, heartRateVariabilitySDNN, vo2Max, oxygenSaturation |
| Respiratory | respiratoryRate |
| Body | bodyMass, height, bmi, bodyFatPercentage, leanBodyMass, waistCircumference, bodyTemperature |
| Blood | bloodGlucose, insulinDelivery, bloodPressure, bloodPressureSystolic, bloodPressureDiastolic |
| Nutrition | dietaryEnergyConsumed, dietaryCarbohydrates, dietaryProtein, dietaryFatTotal, dietaryWater |
| Sleep | sleep, mindfulSession |
| Reproductive | menstrualFlow, cervicalMucusQuality, ovulationTestResult, sexualActivity |
| Workouts | workout (60+ activity types) |

## iOS configuration

Your host app needs these in `Info.plist`:

```xml
<key>NSHealthShareUsageDescription</key>
<string>This app syncs your health data to your account.</string>

<key>UIBackgroundModes</key>
<array>
    <string>fetch</string>
    <string>processing</string>
</array>

<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
    <string>com.openwearables.healthsdk.task.refresh</string>
    <string>com.openwearables.healthsdk.task.process</string>
</array>
```

And HealthKit must be enabled in Signing & Capabilities.

## License

MIT

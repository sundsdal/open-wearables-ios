Pod::Spec.new do |s|
  s.name             = 'OpenWearablesHealthCore'
  s.version          = '0.1.0'
  s.summary          = 'Core iOS health data sync engine for Open Wearables.'
  s.description      = <<-DESC
Shared Swift library for background health data synchronization from Apple HealthKit.
Used by both the Flutter and React Native SDKs.
  DESC
  s.homepage         = 'https://openwearables.io'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'Open Wearables' => 'hello@openwearables.io' }
  s.source           = { :git => 'https://github.com/openwearables/health-core-ios.git', :tag => s.version.to_s }

  s.source_files = 'Sources/OpenWearablesHealthCore/**/*.{swift}'

  s.platform = :ios, '14.0'
  s.swift_version = '5.0'

  s.frameworks = 'HealthKit', 'BackgroundTasks', 'UIKit'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }
end

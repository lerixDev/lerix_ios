Pod::Spec.new do |s|
  s.name             = 'Lerix'
  s.version          = '1.3.0'
  s.summary          = 'Lerix SDK for native iOS: crash reporting, push notifications, in-app feedback, NPS and analytics.'
  s.description      = <<-DESC
    Native Swift SDK for Lerix, the developer monitoring and engagement platform.
    Registers your app and device, reports crashes and handled errors with device
    and app context, and delivers APNs push notifications with topics, images and
    custom sounds. Collects in-app feedback (screenshots with drawing, masking,
    shake to report), runs NPS surveys and records product analytics (events,
    sessions, screens) through a durable offline outbox. Feature parity with the
    Lerix Flutter, Android and web SDKs.
  DESC
  s.homepage         = 'https://lerix.dev'
  s.documentation_url = 'https://docs.lerix.dev/frameworks/ios/installation'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'Lerix' => 'support@lerix.dev' }
  s.source           = { :git => 'https://github.com/lerixDev/lerix_ios.git', :tag => s.version.to_s }

  s.ios.deployment_target = '13.0'
  s.osx.deployment_target = '11.0'
  s.swift_versions   = ['5.9']

  s.source_files     = 'Sources/Lerix/**/*.swift'
  # UI strings (EN + AR). Loaded from Lerix.bundle (see LerixUI.resourceBundle).
  s.resource_bundles = { 'Lerix' => ['Sources/Lerix/Resources/*.lproj'] }
  s.frameworks       = 'Foundation', 'Security', 'UserNotifications', 'SwiftUI', 'ImageIO'
  s.ios.frameworks   = 'UIKit', 'PencilKit'
  s.osx.frameworks   = 'AppKit'
end

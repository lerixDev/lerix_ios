Pod::Spec.new do |s|
  s.name             = 'Lerix'
  s.version          = '1.0.0'
  s.summary          = 'Lerix SDK for native iOS: crash reporting, error tracking and push notifications.'
  s.description      = <<-DESC
    Native Swift SDK for Lerix, the developer monitoring and engagement platform.
    Registers your app and device, reports crashes and handled errors with device
    and app context, and delivers APNs push notifications with topics, images and
    custom sounds. Feature parity with the Lerix Flutter, Android and web SDKs.
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
  s.frameworks       = 'Foundation', 'Security', 'UserNotifications'
  s.ios.frameworks   = 'UIKit'
end

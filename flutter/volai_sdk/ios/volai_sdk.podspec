Pod::Spec.new do |s|
  s.name             = 'volai_sdk'
  s.version          = '0.1.2'
  s.summary          = 'Flutter client for the Volai SDK contract: chat and WebSocket PCM voice.'
  s.description      = 'Bridges the native iOS Volai library (vendored in volai_sdk/Sources/volai_sdk/VolaiSDK) to Flutter over platform channels.'
  s.homepage         = 'https://github.com/Globitel/volai-sdk'
  s.license          = { :type => 'Apache-2.0', :file => '../../../LICENSE' }
  s.author           = 'Globitel'
  s.source           = { :path => '.' }
  s.source_files     = 'volai_sdk/Sources/volai_sdk/**/*.swift'
  s.dependency 'Flutter'
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.9'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end

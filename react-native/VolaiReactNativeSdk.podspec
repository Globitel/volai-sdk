require "json"
package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "VolaiReactNativeSdk"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.license      = package["license"]
  s.authors      = "Globitel"
  s.homepage     = "https://github.com/Globitel/volai-sdk"
  s.platforms    = { :ios => "15.0" }
  s.source       = { :git => "https://github.com/Globitel/volai-sdk.git", :tag => "react-native-v#{s.version}" }
  s.source_files = "ios/**/*.{swift,h,m}"
  s.swift_version = "5.9"
  s.dependency "React-Core"
end

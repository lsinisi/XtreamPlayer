# Librerie esterne: VLC per il player universale (legge MKV, AVI, audio Dolby, DTS…)
platform :ios, '15.0'
project 'XtreamPlayer.xcodeproj'
use_frameworks!

target 'XtreamPlayer' do
  pod 'MobileVLCKit', '~> 3.5'
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
      config.build_settings['ENABLE_BITCODE'] = 'NO'
      config.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
    end
  end
end

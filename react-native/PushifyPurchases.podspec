Pod::Spec.new do |s|
  s.name = 'PushifyPurchases'
  s.version = '0.1.0'
  s.summary = 'Pushify purchases and subscriptions for React Native.'
  s.homepage = 'https://pushify.app'
  s.license = { :type => 'MIT' }
  s.author = { 'Pushify' => 'support@pushify.app' }
  s.source = { :git => 'https://github.com/revenuedot/pushify-sdk.git', :tag => s.version.to_s }
  s.source_files = 'ios/**/*.{h,m,mm,swift}'
  s.dependency 'React-Core'
  s.platform = :ios, '15.0'
  s.swift_version = '5.9'
end

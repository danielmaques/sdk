Pod::Spec.new do |s|
  s.name             = 'pushify_purchases'
  s.version          = '0.1.0'
  s.summary          = 'Pushify purchases and subscriptions for Flutter.'
  s.description      = 'Original Flutter plugin for the Pushify in-app purchases and subscriptions platform.'
  s.homepage         = 'https://pushify.app'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Pushify' => 'support@pushify.app' }
  s.source           = { :path => '.' }
  s.source_files     = 'pushify_purchases/Sources/pushify_purchases/**/*.swift'
  s.dependency 'Flutter'
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.9'
end

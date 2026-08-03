Pod::Spec.new do |s|
  s.name           = 'GaussianScan'
  s.version        = '1.0.0'
  s.summary        = 'ARKit-based capture module for gaussian splat training data'
  s.description    = 'Native ARKit scanning view with frame quality analysis, coverage mapping and keyframe selection.'
  s.author         = ''
  s.homepage       = 'https://docs.expo.dev/modules/'
  s.platforms      = {
    :ios => '16.4'
  }
  s.source         = { git: '' }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'

  s.frameworks = 'ARKit', 'SceneKit', 'Accelerate', 'CoreImage'

  # Swift/Objective-C compatibility
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
  }

  s.source_files = "**/*.{h,m,mm,swift,hpp,cpp}"
end

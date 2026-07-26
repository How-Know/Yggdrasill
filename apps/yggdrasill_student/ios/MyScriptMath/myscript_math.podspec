Pod::Spec.new do |s|
  s.name             = 'myscript_math'
  s.version          = '0.1.0'
  s.summary          = 'MyScript iink math handwriting recognition bridge (PoC)'
  s.description      = <<-DESC
Off-screen math handwriting recognition for the Yggdrasill student app.
Wraps the MyScript iink Math Recognizer (batch pointer events -> LaTeX)
behind a small Swift API consumed from Flutter via a MethodChannel.
The MyScript certificate (MyCertificate.c) ships as a placeholder; replace
it with the one issued on developer.myscript.com to activate the engine.
  DESC
  s.homepage         = 'https://developer.myscript.com/'
  s.license          = { :type => 'Commercial', :text => 'Internal PoC use only.' }
  s.author           = { 'Yggdrasill' => 'dev@yggdrasill.internal' }
  s.source           = { :path => '.' }
  s.platform         = :ios, '15.5'
  s.swift_version    = '5.0'

  # iink C/ObjC 헤더는 SPM 배포판(Sources/libiink/include)에서 복사해 pod 소스로
  # 직접 제공한다. xcframework 내장 헤더는 <iink/...> 중첩 참조 구조라 프레임워크
  # 모듈로는 해석되지 않기 때문. header_mappings_dir 로 iink/ 디렉토리 구조를
  # 유지해야 중첩 include 가 풀린다 (pod 은 static library 로 빌드해야 함).
  s.source_files        = 'Classes/**/*.{swift,c}', 'Headers/**/*.h'
  s.public_header_files = 'Headers/**/*.h'
  s.header_mappings_dir = 'Headers'
  # math2 인식 리소스(conf + res)와 iink 에디터용 수식 폰트.
  # 앱 번들 안에 그대로 복사된다 (폰트는 Runner Info.plist 의 UIAppFonts 에도 등록).
  s.resources           = ['Resources/recognition-assets', 'Resources/fonts/*.otf']

  # iink SDK 4.5 (SPM 배포판의 xcframework, 링크/임베드 전용).
  # 용량(500MB+) 때문에 git 에는 넣지 않는다 — 없으면 fetch_iink_sdk.sh 실행.
  s.vendored_frameworks = 'Frameworks/libiink.xcframework'
  s.frameworks          = ['Foundation', 'Security', 'SystemConfiguration']
  s.libraries           = 'c++'
end

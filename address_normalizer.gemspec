Gem::Specification.new do |s|
  s.name          = "address_normalizer"
  s.version       = "0.1.0"
  s.summary       = "Rust-powered address normalizer (prebuilt binary)"
  s.authors       = ["you"]
  s.files         = Dir["lib/**/*.rb"] + ["ext/address_normalizer/extconf.rb"]
  s.extensions    = ["ext/address_normalizer/extconf.rb"]
  s.require_paths = ["lib"]
end

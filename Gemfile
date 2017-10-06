source "https://rubygems.org"

gemspec
gem 'rdf',              git: "https://github.com/ruby-rdf/rdf",             branch: "develop"
gem 'rdf-spec',         git: "https://github.com/ruby-rdf/rdf-spec",        branch: "develop"

group :development do
  gem 'ebnf',           git: "https://github.com/gkellogg/ebnf",            branch: "develop"
  gem 'sxp',            git: "https://github.com/dryruby/sxp.rb",           branch: "develop"
  gem 'rdf-isomorphic', git: "https://github.com/ruby-rdf/rdf-isomorphic",  branch: "develop"
  gem 'rdf-trig',       git: "https://github.com/ruby-rdf/rdf-trig",        branch: "develop"
  gem 'rdf-vocab',      git: "https://github.com/ruby-rdf/rdf-vocab",       branch: "develop"
  gem 'rdf-xsd',        git: "https://github.com/ruby-rdf/rdf-xsd",         branch: "develop"
  gem 'fasterer'
  gem 'earl-report'
end

group :development, :test do
  gem 'simplecov',  require: false, platform: :mri
  gem 'coveralls',  require: false, platform: :mri
  gem 'psych',      platforms: [:mri, :rbx]
  gem 'benchmark-ips'
  gem 'rake'
end

group :debug do
  gem "byebug", platforms: :mri
end

platforms :rbx do
  gem 'rubysl',   '~> 2.0'
  gem 'rubinius', '~> 2.0'
end

platforms :jruby do
  gem 'gson',     '~> 0.6'
end

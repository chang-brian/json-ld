require 'json/ld'

# For now, override RDF::Utils::File.open_file to look for the file locally before attempting to retrieve it
module RDF::Util
  module File
    LOCAL_PATHS = {
      "https://w3c.github.io/json-ld-api/tests/" => ::File.expand_path("../json-ld-api/tests", __FILE__) + '/',
      "https://w3c.github.io/json-ld-framing/tests/" => ::File.expand_path("../json-ld-framing/tests", __FILE__) + '/',
      "https://w3c.github.io/json-ld-streaming/tests/" => ::File.expand_path("../json-ld-streaming/tests", __FILE__) + '/',
      "https://json-ld.github.io/json-ld-star/tests/" => ::File.expand_path("../json-ld-star/tests", __FILE__) + '/',
      "file:" => ""
    }

    class << self
      alias_method :original_open_file, :open_file
    end

    ##
    # Override to use Patron for http and https, Kernel.open otherwise.
    #
    # @param [String] filename_or_url to open
    # @param  [Hash{Symbol => Object}] options
    # @option options [Array, String] :headers
    #   HTTP Request headers.
    # @return [IO] File stream
    # @yield [IO] File stream
    def self.open_file(filename_or_url, **options, &block)
      LOCAL_PATHS.each do |r, l|
        next unless Dir.exist?(l) && filename_or_url.start_with?(r)
        #puts "attempt to open #{filename_or_url} locally"
        url_no_frag_or_query = RDF::URI(filename_or_url).dup
        url_no_frag_or_query.query = nil
        url_no_frag_or_query.fragment = nil
        localpath = url_no_frag_or_query.to_s.sub(r, l)
        response = begin
          ::File.open(localpath)
        rescue Errno::ENOENT => e
          raise IOError, e.message
        end

        document_options = {
          base_uri:     RDF::URI(filename_or_url),
          charset:      Encoding::UTF_8,
          code:         200,
          headers:      options.fetch(:headers, {})
        }
        #puts "use #{filename_or_url} locally"
        document_options[:headers][:content_type] = case localpath
        when /\.ttl$/    then 'text/turtle'
        when /\.nq$/     then 'application/n-quads'
        when /\.nt$/     then 'application/n-triples'
        when /\.html$/   then 'text/html'
        when /\.jsonld$/ then 'application/ld+json'
        when /\.json$/   then 'application/json'
        else                  'unknown'
        end

        document_options[:headers][:content_type] = response.content_type if response.respond_to?(:content_type)
        # For overriding content type from test data
        document_options[:headers][:content_type] = options[:contentType] if options[:contentType]

        remote_document = RDF::Util::File::RemoteDocument.new(response.read, **document_options)
        if block_given?
          return yield remote_document
        else
          return remote_document
        end
      end

      original_open_file(filename_or_url, **options, &block)
    end
  end
end

module Fixtures
  module SuiteTest
    SUITE = RDF::URI("https://w3c.github.io/json-ld-api/tests/")
    FRAME_SUITE = RDF::URI("https://w3c.github.io/json-ld-framing/tests/")
    STREAM_SUITE = RDF::URI("https://w3c.github.io/json-ld-streaming/tests/")
    STAR_SUITE = RDF::URI("https://json-ld.github.io/json-ld-star/tests/")

    class Manifest < JSON::LD::Resource
      attr_accessor :manifest_url

      def self.open(file)
        RDF::Util::File.open_file(file) do |remote|
          json = JSON.parse(remote.read)
          if block_given?
            yield self.from_jsonld(json, manifest_url: RDF::URI(file))
          else
            self.from_jsonld(json, manifest_url: RDF::URI(file))
          end
        end
      end

      def initialize(json, manifest_url:)
        @manifest_url = manifest_url
        super
      end

      # @param [Hash] json framed JSON-LD
      # @return [Array<Manifest>]
      def self.from_jsonld(json, manifest_url: )
        Manifest.new(json, manifest_url: manifest_url)
      end

      def entries
        # Map entries to resources
        attributes['sequence'].map do |e|
          e.is_a?(String) ? Manifest.open(manifest_url.join(e).to_s) : Entry.new(e, manifest_url: manifest_url)
        end
      end
    end

    class Entry < JSON::LD::Resource
      attr_accessor :logger
      attr_accessor :manifest_url

      def initialize(json, manifest_url:)
        @manifest_url = manifest_url
        super
      end

      # Base is expanded input if not specified
      def base
        options.fetch('base', manifest_url.join(property('input')).to_s)
      end

      def options
        @options ||= begin
          opts = {
            documentLoader: Fixtures::SuiteTest.method(:documentLoader),
            validate: true,
            lowercaseLanguage: true,
          }
          {'specVersion' => "json-ld-1.1"}.merge(property('option') || {}).each do |k, v|
            opts[k.to_sym] = v
          end
          if opts[:expandContext] && !RDF::URI(opts[:expandContext]).absolute?
            # Resolve relative to manifest location
            opts[:expandContext] = manifest_url.join(opts[:expandContext]).to_s
          end
          opts
        end
      end

      # Alias input, context, expect and frame
      %w(input context expect frame).each do |m|
        define_method(m.to_sym) do
          return nil unless property(m)
          res = nil
          file = self.send("#{m}_loc".to_sym)

          dl_opts = {safe: true}
          dl_opts[:contentType] = options[:contentType] if m == 'input' && options[:contentType]
          RDF::Util::File.open_file(file, **dl_opts) do |remote_doc|
            res = remote_doc.read
          end
          res
        end

        define_method("#{m}_loc".to_sym) do
          file = property(m)

          # Handle redirection internally
          if m == "input" && options[:redirectTo]
            file = options[:redirectTo]
          end

          property(m) && manifest_url.join(file).to_s
        end

        define_method("#{m}_json".to_sym) do
          JSON.parse(self.send(m)) if property(m)
        end
      end

      def testType
        property('@type').reject {|t| t =~ /EvaluationTest|SyntaxTest/}.first
      end

      def evaluationTest?
        property('@type').to_s.include?('EvaluationTest')
      end

      def positiveTest?
        property('@type').to_s.include?('Positive')
      end

      def syntaxTest?
        property('@type').to_s.include?('Syntax')
      end
      

      # Execute the test
      def run(rspec_example = nil)
        logger = @logger = RDF::Spec.logger
        logger.info "test: #{inspect}"
        logger.info "purpose: #{purpose}"
        logger.info "source: #{input rescue nil}"
        logger.info "context: #{context}" if context_loc
        logger.info "options: #{options.inspect}" unless options.empty?
        logger.info "frame: #{frame}" if frame_loc

        options = self.options
        if options[:specVersion] == "json-ld-1.0"
          skip "1.0 test" 
          return
        end

        # Because we're doing exact comparisons when ordered.
        options[:lowercaseLanguage] = true if options[:ordered]

        if positiveTest?
          logger.info "expected: #{expect rescue nil}" if expect_loc
          begin
            result = case testType
            when "jld:ExpandTest"
              JSON::LD::API.expand(input_loc, logger: logger, **options)
            when "jld:CompactTest"
              JSON::LD::API.compact(input_loc, context_json['@context'], logger: logger, **options)
            when "jld:FlattenTest"
              JSON::LD::API.flatten(input_loc, (context_json['@context'] if context_loc), logger: logger, **options)
            when "jld:FrameTest"
              JSON::LD::API.frame(input_loc, frame_loc, logger: logger, **options)
            when "jld:FromRDFTest"
              # Use an array, to preserve input order
              repo = RDF::NQuads::Reader.open(input_loc, rdfstar: options[:rdfstar]) do |reader|
                reader.each_statement.to_a
              end.to_a.uniq.extend(RDF::Enumerable)
              logger.info "repo: #{repo.dump(self.id == '#t0012' ? :nquads : :trig)}"
              JSON::LD::API.fromRdf(repo, logger: logger, **options)
            when "jld:ToRDFTest"
              repo = RDF::Repository.new
              if manifest_url.to_s.include?('stream')
                JSON::LD::Reader.open(input_loc, stream: true, logger: logger, **options) do |statement|
                  repo << statement
                end
              else
                JSON::LD::API.toRdf(input_loc, rename_bnodes: false, logger: logger, **options) do |statement|
                  repo << statement
                end
              end
              logger.info "nq: #{repo.map(&:to_nquads)}"
              repo
            when "jld:HttpTest"
              res = input_json
              rspec_example.instance_eval do
                # use the parsed input file as @result for Rack Test application
                @results = res
                get "/", {}, "HTTP_ACCEPT" => options.fetch(:httpAccept, ""), "HTTP_LINK" => options.fetch(:httpLink, nil)
                expect(last_response.status).to eq 200
                expect(last_response.content_type).to eq options.fetch(:contentType, "")
                JSON.parse(last_response.body)
              end
            else
              fail("Unknown test type: #{testType}")
            end
            if evaluationTest?
              if testType == "jld:ToRDFTest"
                expected = RDF::Repository.new << RDF::NQuads::Reader.new(expect, rdfstar: options[:rdfstar], logger: [])
                rspec_example.instance_eval {
                  expect(result).to be_equivalent_graph(expected, logger)
                }
              else
                expected = JSON.load(expect)

                # If called for, remap bnodes
                result = remap_bnodes(result, expected) if options[:remap_bnodes]

                if options[:ordered]
                  # Compare without transformation
                  rspec_example.instance_eval {
                    expect(result).to produce(expected, logger)
                  }
                else
                  # Without key ordering, reorder result and expected embedded array values and compare
                  # If results are compacted, expand both, reorder and re-compare
                  rspec_example.instance_eval {
                    expect(result).to produce_jsonld(expected, logger)
                  }

                  # If results are compacted, expand both, reorder and re-compare
                  if result.to_s.include?('@context')
                    exp_expected = JSON::LD::API.expand(expected, **options)
                    exp_result = JSON::LD::API.expand(result, **options)
                    rspec_example.instance_eval {
                      expect(exp_result).to produce_jsonld(exp_expected, logger)
                    }
                  end
                end
              end
            else
              rspec_example.instance_eval {
                expect(result).to_not be_nil
              }
            end
          rescue JSON::LD::JsonLdError => e
            fail("Processing error: #{e.message}")
          end
        else
          logger.info "expected: #{property('expect')}" if property('expect')
          t = self
          rspec_example.instance_eval do
            if t.evaluationTest?
              expect do
                case t.testType
                when "jld:ExpandTest"
                  JSON::LD::API.expand(t.input_loc, logger: logger, **options)
                when "jld:CompactTest"
                  JSON::LD::API.compact(t.input_loc, t.context_json['@context'], logger: logger, **options)
                when "jld:FlattenTest"
                  JSON::LD::API.flatten(t.input_loc, t.context_loc, logger: logger, **options)
                when "jld:FrameTest"
                  JSON::LD::API.frame(t.input_loc, t.frame_loc, logger: logger, **options)
                when "jld:FromRDFTest"
                  repo = RDF::Repository.load(t.input_loc, rdfstar: options[:rdfstar])
                  logger.info "repo: #{repo.dump(t.id == '#t0012' ? :nquads : :trig)}"
                  JSON::LD::API.fromRdf(repo, logger: logger, **options)
                when "jld:HttpTest"
                  rspec_example.instance_eval do
                    # use the parsed input file as @result for Rack Test application
                    @results = t.input_json
                    get "/", {}, "HTTP_ACCEPT" => options.fetch(:httpAccept, "")
                    expect(last_response.status).to eq t.property('expect')
                    expect(last_response.content_type).to eq options.fetch(:contentType, "")
                    raise "406" if t.property('expect') == 406
                    raise "Expected status #{t.property('expectErrorCode')}, not #{last_response.status}"
                  end
                when "jld:ToRDFTest"
                  if t.manifest_url.to_s.include?('stream')
                    JSON::LD::Reader.open(t.input_loc, stream: true, logger: logger, **options).each_statement {}
                  else
                    JSON::LD::API.toRdf(t.input_loc, rename_bnodes: false, logger: logger, **options) {}
                  end
                else
                  success("Unknown test type: #{testType}")
                end
              end.to raise_error(/#{t.property('expectErrorCode')}/)
            else
              fail("No support for NegativeSyntaxTest")
            end
          end
        end
      end

      # Don't use NQuads writer so that we don't escape Unicode
      def to_quad(thing)
        case thing
        when RDF::URI
          thing.to_ntriples
        when RDF::Node
          escaped(thing)
        when RDF::Literal::Double
          thing.canonicalize.to_ntriples
        when RDF::Literal
          v = quoted(escaped(thing.value))
          case thing.datatype
          when nil, "http://www.w3.org/2001/XMLSchema#string", "http://www.w3.org/1999/02/22-rdf-syntax-ns#langString"
            # Ignore these
          else
            v += "^^#{to_quad(thing.datatype)}"
          end
          v += "@#{thing.language}" if thing.language
          v
        when RDF::Statement
          thing.to_quad.map {|r| to_quad(r)}.compact.join(" ") + " .\n"
        end
      end

      ##
      # @param  [String] string
      # @return [String]
      def quoted(string)
        "\"#{string}\""
      end

      ##
      # @param  [String, #to_s] string
      # @return [String]
      def escaped(string)
        string.to_s.gsub('\\', '\\\\').gsub("\t", '\\t').
          gsub("\n", '\\n').gsub("\r", '\\r').gsub('"', '\\"')
      end
    end

    ##
    # Document loader to use for tests having `useDocumentLoader` option
    #
    # @param [RDF::URI, String] url
    # @param [Hash<Symbol => Object>] options
    # @option options [Boolean] :validate
    #   Allow only appropriate content types
    # @return [RDF::Util::File::RemoteDocument] retrieved remote document and context information unless block given
    # @yield remote_document
    # @yieldparam [RDF::Util::File::RemoteDocument] remote_document
    # @raise [JsonLdError]
    def documentLoader(url, **options, &block)
      options[:headers] ||= JSON::LD::API::OPEN_OPTS[:headers].dup
      options[:headers][:link] = Array(options[:httpLink]).join(',') if options[:httpLink]
    
      url = url.to_s[5..-1] if url.to_s.start_with?("file:")
      JSON::LD::API.documentLoader(url, **options, &block)
    rescue JSON::LD::JsonLdError::LoadingDocumentFailed, JSON::LD::JsonLdError::MultipleContextLinkHeaders
      raise unless options[:safe]
      "don't raise error"
    end
    module_function :documentLoader
  end
end

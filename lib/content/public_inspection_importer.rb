module Content
  class PublicInspectionImporter
    def self.perform
      if ENV['PI_FILE']
        html = File.read(ENV['PI_FILE'])
      else
        curl = Curl::Easy.new('http://www.ofr.gov/inspection.aspx')
        curl.follow_location = true
        curl.perform
        html = curl.body_str

        save_file(html)
      end

      parser = Nokogiri::HTML::SAX::Parser.new(Parser.new)
      parser.encoding = 'utf8'
      parser.parse(html)
      parser.document.import!
    end

    def self.import(attributes)
      pi = new(attributes)
      pi.save
    end

    def self.save_file(html)
      dir = FileUtils.mkdir_p("/var/www/apps/fr2/shared/data/public_inspection/html/#{Time.now.strftime('%Y/%m/%d')}/")
      f = File.new("#{dir.to_s}/#{Time.now.to_s(:HMS_Z)}.html", "w")
      f.write(html)
      f.close
    end

    def initialize(attributes)
      @pi = PublicInspectionDocument.find_or_initialize_by_document_number(attributes.delete(:document_number))
      attributes.each_pair do |attr,val|
        send("#{attr}=", val)
      end
    end

    def save
      @pi.save
    end

    [:document_number, :granule_class, :toc_subject, :toc_doc, :title, :filed_at, :publication_date, :docket_id, :editorial_note].each do |attr|
      define_method "#{attr}=" do |val|
        @pi.send("#{attr}=", val)
      end
    end

    def details=(val)
      val.sub!(/^\[/,'').sub!(/\]$/,'')
      val.split(/\s*;\s*/).each do |part|
        case part
        when /Filed: (.+)/
          self.filed_at = $1
        when /Publication Date: (.+)/
          self.publication_date = $1
        when /Docket No. (.+)/
          self.docket_id = $1
        else
          # TODO: internal_docket_id ?
          # TODO: multiple docket numbers?
        end
      end
    end

    def agency=(val)
      if val.present?
        agency_name = AgencyName.find_or_create_by_name(val)
        @pi.agency_names = [agency_name]
      else
        @pi.agency_names = []
      end
    end

    def url=(url)
      if url !~ /^http/
        url = "http://www.ofr.gov/" + url
      end

      if !ENV['SKIP_DOWNLOADS'] && (not_already_downloaded? || etag_from_head(url) != @pi.pdf_etag)
        path = File.join(Dir.tmpdir, File.basename(url))
        curl = Curl::Easy.download(url, path)
        headers = HttpHeaders.new(curl.header_str)
        @pi.pdf_file_name = @pi.pdf_etag = headers.etag
        @pi.pdf = File.new(path)
        File.delete(path)
      end
    end

    def filing_type=(val)
      @pi.special_filing = val == 'special'
    end

    def not_already_downloaded?
      @pi.pdf.url.blank?
    end

    def etag_from_head(url)
      curl = Curl::Easy.http_head(url)
      headers = HttpHeaders.new(curl.header_str)
      headers.etag
    end

    class Parser < Nokogiri::XML::SAX::Document
      GRANULE_CLASSES = {
        "NOTICES" => "NOTICE",
        "RULES" => "RULE",
        "PROPOSED RULES" => "PRORULE",
        "PRESIDENTIAL DOCUMENTS" => "PRESDOCU"
      }
      attr_reader :pi_documents
      def initialize(*args)
        @str = ''
        @pi_documents = []
        super
      end

      def start_element(name, raw_attributes = [])
        if @str.present?
          handle_characters
          @str = ''
        end

        attributes = Hash[*raw_attributes]

        # ensure we're only parsing the main document body
        case attributes['id']
        when 'content-body'
          @in_body = true
        when 'Footer'
          @in_body = false
        end
        return unless @in_body

        case name
        when 'blockquote'
          @context = :document_number_or_toc_doc
        when 'p'
          @context = :toc_subject
        when 'b'
          @context = :agency_or_granule_class_or_editorial_note
        when 'a'
          if attributes['href'] && attributes['target']
            @url = attributes['href']
            @context = :details if attributes['href']
          elsif ['special', 'regular'].include?(attributes['name'])
            @filing_type = attributes['name']
          end
        end
      end

      # SAX parsers don't guarantee that you get all of the characters at
      #   once, and in practice we're getting split apart at special
      #   character entities, so rather than doing the actual logic
      #   with the character callback, we're storing the accumulated
      #   characters and them processing them when the next element
      #   begins.
      def characters(str)
        @str += str.gsub(/\302\240/, ' ')
      end

      def handle_characters
        # normalize whitespace
        @str.gsub!(/\s+/, ' ')
        @str.strip!

        case @context
        when :agency_or_granule_class_or_editorial_note
          if @str =~ /^EDITORIAL NOTE: /
            @pi_documents.last[:editorial_note] = @str.sub(/^EDITORIAL NOTE: /,'')
          else
            if GRANULE_CLASSES[@str]
              @granule_class = GRANULE_CLASSES[@str]
            else
              @agency = @str
            end
          end
        when :document_number_or_toc_doc
          if @document_number
            @toc_doc = @document_number
          end
          @document_number = @str
        when :editorial_note
          @pi_documents.last[:editorial_note] = @str
        when :toc_subject
          @toc_subject = @str
          @toc_doc = nil
        when :details
          @details = @str

          if @granule_class == 'PRESDOCU'
            # throw out the 'PROCLAMATION', etc for now
            @agency = 'Executive Office of the President'
          end

          if @toc_doc.blank? && @toc_subject.present?
            @title = @toc_subject.dup
            @toc_subject = nil
          end

          @pi_documents << {
            :filing_type     => @filing_type,
            :details         => @details,
            :agency          => @agency,
            :granule_class   => @granule_class,
            :document_number => @document_number,
            :toc_subject     => @toc_subject,
            :toc_doc         => @toc_doc,
            :title           => @title || '',
            :url             => @url
          }
          @document_number = nil
          @title = '' if @toc_doc.present?
        end
      end

      def import!
        @pi_documents.each do |attr|
          Content::PublicInspectionImporter.import(attr)
        end
      end
    end
  end
end

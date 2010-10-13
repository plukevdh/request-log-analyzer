module RequestLogAnalyzer::Aggregator
  class OracleInserter < Base

    attr_reader :request_count, :sources, :database

    # Establishes a connection to the database and creates the necessary database schema for the
    # current file format
    def prepare
      @sources = {}
      @database =  RequestLogAnalyzer::Database.new(options[:database][1..-1])
      @database.file_format = source.file_format

      database.drop_database_schema! if options[:reset_database]
      database.create_database_schema!
    end

    # Aggregates a request into the database
    # This will create a record in the requests table and create a record for every line that has been parsed,
    # in which the captured values will be stored.
    def aggregate(request)
      @request_object = RequestLogAnalyzer::Database::Request.new(:first_lineno => request.first_lineno, :last_lineno => request.last_lineno)
      request.lines.each do |line|
        class_columns = database.get_class(line[:line_type]).column_names.reject { |column| ['id', 'source_id', 'request_id'].include?(column) }
        attributes = Hash[*line.select { |(k, v)| class_columns.include?(k.to_s) }.flatten]
        attributes[:source_id] = @sources[line[:source]].id if @sources[line[:source]]
        @request_object.send("#{line[:line_type]}_lines").build(attributes)
      end
      @request_object.save!
    rescue OracleEnhanced::OCIException => e
      raise Interrupt, e.message
    end

    # Finalizes the aggregator by closing the connection to the database
    def finalize
      @request_count = RequestLogAnalyzer::Database::Request.count
      database.disconnect
      database.remove_orm_classes!
    end

    # Records w warining in the warnings table.
    def warning(type, message, lineno)
      RequestLogAnalyzer::Database::Warning.create!(:warning_type => type.to_s, :message => message, :lineno => lineno)
    end

    # Records source changes in the sources table
    def source_change(change, filename)
      if File.exist?(filename)
        case change
        when :started
          @sources[filename] = RequestLogAnalyzer::Database::Source.create!(:filename => filename)
        when :finished
          @sources[filename].update_attributes!(:filesize => File.size(filename), :mtime => File.mtime(filename))
        end
      end
    end

    # Prints a short report of what has been inserted into the database
    def report(output)
      output.title('Request database created')

      output <<  "An oracle database has been created with all parsed request information.\n"
      output <<  "#{@request_count} requests have been added to the database.\n"
      output << "\n"
      output <<  "To open a Ruby console to inspect the database, run the following command.\n"
      output <<  output.colorize("  $ request-log-analyzer console -d #{options[:database]}\n", :bold)
      output << "\n"
    end

  end
end

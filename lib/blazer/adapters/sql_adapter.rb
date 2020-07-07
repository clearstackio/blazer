module Blazer
  module Adapters
    class SqlAdapter < BaseAdapter
      attr_reader :connection_model

      def initialize(data_source)
        super

        @connection_model =
          Class.new(Blazer::Connection) do
            def self.name
              "Blazer::Connection::Adapter#{object_id}"
            end
            establish_connection(data_source.settings["url"]) if data_source.settings["url"]
          end
      end

      def run_statement(statement, comment, options = {})
        columns = []
        rows = []
        error = nil

        options[:force] ||= false

        begin
          check_if_table_queriable?(statement) unless options[:force]
          in_transaction do
            set_timeout(data_source.timeout) if data_source.timeout

            result = select_all("#{statement} /*#{comment}*/")
            columns = result.columns
            result.rows.each do |untyped_row|
              rows << (result.column_types.empty? ? untyped_row : columns.each_with_index.map { |c, i| untyped_row[i] ? result.column_types[c].send(:cast_value, untyped_row[i]) : untyped_row[i] })
            end
          end
        rescue => e
          error = e.message.sub(/.+ERROR: /, "")
          error = Blazer::TIMEOUT_MESSAGE if Blazer::TIMEOUT_ERRORS.any? { |e| error.include?(e) }
          reconnect if error.include?("PG::ConnectionBad")
        end

        [columns, rows, error]
      end

      def tables
        if information_schema_present_for_oracle_enhanced?
          sql = add_schemas("SELECT table_schema, table_name FROM information_schema.tables")
        else
          sql = add_schemas("SELECT * FROM (SELECT owner as table_schema, table_name FROM all_tables)")
        end
        result = data_source.run_statement(sql, refresh_cache: true, force: true)
        if postgresql? || redshift? || snowflake?
          result.rows.sort_by { |r| [r[0] == default_schema ? "" : r[0], r[1]] }.map do |row|
            table =
              if row[0] == default_schema
                row[1]
              else
                "#{row[0]}.#{row[1]}"
              end

            table = table.downcase if snowflake?

            {
              table: table,
              value: connection_model.connection.quote_table_name(table)
            }
          end
        else
          result.rows.map(&:second).sort
        end
      end

      def schema
        if information_schema_present_for_oracle_enhanced?
          sql = add_schemas("SELECT table_schema, table_name, column_name, data_type, ordinal_position FROM information_schema.columns")
        else
          sql = add_schemas("SELECT * FROM (SELECT owner as table_schema, table_name, column_name, data_type, 0 as ordinal_position FROM ALL_TAB_COLUMNS)")
        end
        result = data_source.run_statement(sql, force: true)
        result.rows.group_by { |r| [r[0], r[1]] }.map { |k, vs| {schema: k[0], table: k[1], columns: vs.sort_by { |v| v[2] }.map { |v| {name: v[2], data_type: v[3]} }} }.sort_by { |t| [t[:schema] == default_schema ? "" : t[:schema], t[:table]] }
      end

      def preview_statement
        if sqlserver?
          "SELECT TOP (10) * FROM {table}"
        elsif oracle_enhanced?
          "SELECT * FROM {table} WHERE ROWNUM <= 10"
        else
          "SELECT * FROM {table} LIMIT 10"
        end
      end

      def reconnect
        connection_model.establish_connection(settings["url"])
      end

      def cost(statement)
        result = explain(statement)
        if sqlserver?
          result["TotalSubtreeCost"]
        else
          match = /cost=\d+\.\d+..(\d+\.\d+) /.match(result)
          match[1] if match
        end
      end

      def explain(statement)
        if postgresql? || redshift?
          select_all("EXPLAIN #{statement}").rows.first.first
        elsif sqlserver?
          begin
            execute("SET SHOWPLAN_ALL ON")
            result = select_all(statement).each.first
          ensure
            execute("SET SHOWPLAN_ALL OFF")
          end
          result
        end
      rescue
        nil
      end

      def cancel(run_id)
        if postgresql?
          select_all("SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND query LIKE ?", ["%,run_id:#{run_id}%"])
        elsif redshift?
          first_row = select_all("SELECT pid FROM stv_recents WHERE status = 'Running' AND query LIKE ?", ["%,run_id:#{run_id}%"]).first
          if first_row
            select_all("CANCEL #{first_row["pid"].to_i}")
          end
        end
      end

      def cachable?(statement)
        !%w[CREATE ALTER UPDATE INSERT DELETE].include?(statement.split.first.to_s.upcase)
      end

      protected

      def select_all(statement, params = [])
        statement = connection_model.send(:sanitize_sql_array, [statement] + params) if params.any?
        connection_model.connection.select_all(statement)
      end

      # seperate from select_all to prevent mysql error
      def execute(statement)
        connection_model.connection.execute(statement)
      end

      def postgresql?
        ["PostgreSQL", "PostGIS"].include?(adapter_name)
      end

      def redshift?
        ["Redshift"].include?(adapter_name)
      end

      def mysql?
        ["MySQL", "Mysql2", "Mysql2Spatial"].include?(adapter_name)
      end

      def oracle_enhanced?
        ["OracleEnhanced"].include?(adapter_name)
      end

      def sqlserver?
        ["SQLServer", "tinytds", "mssql"].include?(adapter_name)
      end

      def snowflake?
        data_source.adapter == "snowflake"
      end

      def information_schema_present_for_oracle_enhanced?
        if oracle_enhanced?
          sql = "SELECT COUNT(*) FROM information_schema.columns"
          result = data_source.run_statement(sql, force: true)
          !result.error.presence.match?("table or view does not exist")
        else
          true
        end
      end

      def adapter_name
        # prevent bad data source from taking down queries/new
        connection_model.connection.adapter_name rescue nil
      end

      def default_schema
        @default_schema ||= begin
          if postgresql? || redshift?
            "public"
          elsif sqlserver?
            "dbo"
          else
            connection_model.connection_config[:database]
          end
        end
      end

      def add_schemas(query)
        if settings["schemas"]
          where = "table_schema IN (?)"
          schemas = settings["schemas"]
        else
          where = "table_schema NOT IN (?)"
          schemas = ["information_schema"]
          schemas.map!(&:upcase) if snowflake?
          schemas << "pg_catalog" if postgresql? || redshift?
        end
        if only_tables_defined?
          where += " AND table_name IN (?)"
          connection_model.send(:sanitize_sql_array, ["#{query} WHERE #{where}", schemas, settings["only_tables"]])
        elsif except_tables_defined?
          where += " AND table_name NOT IN (?)"
          connection_model.send(:sanitize_sql_array, ["#{query} WHERE #{where}", schemas, settings["except_tables"]])
        else
          connection_model.send(:sanitize_sql_array, ["#{query} WHERE #{where}", schemas])
        end
      end

      def set_timeout(timeout)
        if postgresql? || redshift?
          execute("SET #{use_transaction? ? "LOCAL " : ""}statement_timeout = #{timeout.to_i * 1000}")
        elsif mysql?
          # use send as this method is private in Rails 4.2
          mariadb = connection_model.connection.send(:mariadb?) rescue false
          if mariadb
            execute("SET max_statement_time = #{timeout.to_i * 1000}")
          else
            execute("SET max_execution_time = #{timeout.to_i * 1000}")
          end
        else
          raise Blazer::TimeoutNotSupported, "Timeout not supported for #{adapter_name} adapter"
        end
      end

      def use_transaction?
        settings.key?("use_transaction") ? settings["use_transaction"] : true
      end

      def in_transaction
        connection_model.connection_pool.with_connection do
          if use_transaction?
            connection_model.transaction do
              yield
              raise ActiveRecord::Rollback
            end
          else
            yield
          end
        end
      end

      def check_if_table_queriable?(statement)
        if only_tables_defined?
          check_for_only_tables(statement)
        elsif except_tables_defined?
          check_for_except_tables(statement)
        end
      end

      def check_for_only_tables(statement)
        table_name = parse_table_name_from_statement(statement)
        if table_name
          unless settings['only_tables'].map{|name| name.upcase }.include? table_name
            raise Blazer::Error, "You are now allowed to perform queries on #{table_name} table"
          end
        end
      end

      def check_for_except_tables(statement)
        table_name = parse_table_name_from_statement(statement)
        if table_name
          if settings['except_tables'].map{|name| name.upcase }.include? table_name
            raise Blazer::Error, "You are now allowed to perform queries on #{table_name} table"
          end
        end
      end

      def parse_table_name_from_statement(statement)
        table_name_regex = /FROM [A-Z]+(_[A-Z]+)?(\.[A-Z]+)?/
        table_name = table_name_regex.match(statement&.upcase)
        table_name.to_s.split(' ').last
      end

      def only_tables_defined?
        settings['only_tables'] && settings['only_tables'].is_a?(Array)
      end

      def except_tables_defined?
        settings['except_tables'] && settings['except_tables'].is_a?(Array)
      end
    end
  end
end

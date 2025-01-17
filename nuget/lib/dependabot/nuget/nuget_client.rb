# typed: true
# frozen_string_literal: true

require "dependabot/nuget/cache_manager"
require "dependabot/nuget/update_checker/repository_finder"

module Dependabot
  module Nuget
    class NugetClient
      def self.get_package_versions(dependency_name, repository_details)
        repository_type = repository_details.fetch(:repository_type)
        if repository_type == "v3"
          get_package_versions_v3(dependency_name, repository_details)
        elsif repository_type == "v2"
          get_package_versions_v2(dependency_name, repository_details)
        else
          raise "Unknown repository type: #{repository_type}"
        end
      end

      private_class_method def self.get_package_versions_v3(dependency_name, repository_details)
        # Use the registration URL if possible because it is fast and correct
        if repository_details[:registration_url]
          get_versions_from_registration_v3(repository_details)
        # use the search API if not because it is slow but correct
        elsif repository_details[:search_url]
          get_versions_from_search_url_v3(repository_details, dependency_name)
        # Otherwise, use the versions URL (fast but wrong because it includes unlisted versions)
        elsif repository_details[:versions_url]
          get_versions_from_versions_url_v3(repository_details)
        end
      end

      private_class_method def self.get_package_versions_v2(dependency_name, repository_details)
        doc = execute_xml_nuget_request(repository_details.fetch(:versions_url), repository_details)
        return unless doc

        id_nodes = doc.xpath("/feed/entry/properties/Id")
        matching_versions = Set.new
        id_nodes.each do |id_node|
          return nil unless id_node.text

          next unless id_node.text.casecmp?(dependency_name)

          version_node = id_node.parent.xpath("Version")
          matching_versions << version_node.text if version_node && version_node.text
        end

        matching_versions
      end

      private_class_method def self.get_versions_from_versions_url_v3(repository_details)
        body = execute_json_nuget_request(repository_details[:versions_url], repository_details)
        body&.fetch("versions")
      end

      private_class_method def self.get_versions_from_registration_v3(repository_details)
        url = repository_details[:registration_url]
        body = execute_json_nuget_request(url, repository_details)

        return unless body

        pages = body.fetch("items")
        versions = Set.new
        pages.each do |page|
          items = page["items"]
          if items
            # inlined entries
            items.each do |item|
              catalog_entry = item["catalogEntry"]

              # a package is considered listed if the `listed` property is either `true` or missing
              listed_property = catalog_entry["listed"]
              is_listed = listed_property.nil? || listed_property == true
              if is_listed
                vers = catalog_entry["version"]
                versions << vers
              end
            end
          else
            # paged entries
            page_url = page["@id"]
            page_body = execute_json_nuget_request(page_url, repository_details)
            items = page_body.fetch("items")
            items.each do |item|
              catalog_entry = item.fetch("catalogEntry")
              versions << catalog_entry.fetch("version") if catalog_entry["listed"] == true
            end
          end
        end

        versions
      end

      private_class_method def self.get_versions_from_search_url_v3(repository_details, dependency_name)
        search_url = repository_details[:search_url]
        body = execute_json_nuget_request(search_url, repository_details)

        body&.fetch("data")
            &.find { |d| d.fetch("id").casecmp(dependency_name.downcase).zero? }
            &.fetch("versions")
            &.map { |d| d.fetch("version") }
      end

      private_class_method def self.execute_xml_nuget_request(url, repository_details)
        response = execute_nuget_request_internal(
          url: url,
          auth_header: repository_details[:auth_header],
          repository_url: repository_details[:repository_url]
        )
        return unless response.status == 200

        doc = Nokogiri::XML(response.body)
        doc.remove_namespaces!
        doc
      end

      private_class_method def self.execute_json_nuget_request(url, repository_details)
        response = execute_nuget_request_internal(
          url: url,
          auth_header: repository_details[:auth_header],
          repository_url: repository_details[:repository_url]
        )
        return unless response.status == 200

        body = remove_wrapping_zero_width_chars(response.body)
        JSON.parse(body)
      end

      private_class_method def self.execute_nuget_request_internal(
        url: String,
        auth_header: String,
        repository_url: String
      )
        cache = CacheManager.cache("dependency_url_search_cache")
        if cache[url].nil?
          response = Dependabot::RegistryClient.get(
            url: url,
            headers: auth_header
          )

          if [401, 402, 403].include?(response.status)
            raise Dependabot::PrivateSourceAuthenticationFailure, repository_url
          end

          cache[url] = response if !CacheManager.caching_disabled? && response.status == 200
        else
          response = cache[url]
        end

        response
      rescue Excon::Error::Timeout, Excon::Error::Socket
        repo_url = repository_url
        raise if repo_url == Dependabot::Nuget::UpdateChecker::RepositoryFinder::DEFAULT_REPOSITORY_URL

        raise PrivateSourceTimedOut, repo_url
      end

      private_class_method def self.remove_wrapping_zero_width_chars(string)
        string.force_encoding("UTF-8").encode
              .gsub(/\A[\u200B-\u200D\uFEFF]/, "")
              .gsub(/[\u200B-\u200D\uFEFF]\Z/, "")
      end
    end
  end
end

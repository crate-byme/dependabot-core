# typed: true
# frozen_string_literal: true

require "dependabot/file_fetchers"
require "dependabot/file_fetchers/base"
require "dependabot/devcontainers/utils"

module Dependabot
  module Devcontainers
    class FileFetcher < Dependabot::FileFetchers::Base
      def self.required_files_in?(filenames)
        # There's several other places a devcontainer.json can be checked into
        # See: https://containers.dev/implementors/spec/#devcontainerjson
        filenames.any? { |f| f.end_with?("devcontainer.json") }
      end

      def self.required_files_message
        "Repo must contain a dev container configuration file."
      end

      def fetch_files
        fetched_files = []
        fetched_files += root_files
        fetched_files += scoped_files
        fetched_files += custom_directory_files
        return fetched_files if fetched_files.any?

        raise Dependabot::DependencyFileNotFound.new(
          nil,
          "Neither .devcontainer.json nor .devcontainer/devcontainer.json nor " \
          ".devcontainer/<anything>/devcontainer.json found in #{directory}"
        )
      end

      private

      def root_files
        fetch_config_and_lockfile_from(".")
      end

      def scoped_files
        return [] unless devcontainer_directory

        fetch_config_and_lockfile_from(".devcontainer")
      end

      def custom_directory_files
        return [] unless devcontainer_directory

        custom_directories.flat_map do |directory|
          fetch_config_and_lockfile_from(directory.path)
        end
      end

      def custom_directories
        repo_contents(dir: ".devcontainer").select { |f| f.type == "dir" && f.name != ".devcontainer" }
      end

      def devcontainer_directory
        return @devcontainer_directory if defined?(@devcontainer_directory)

        @devcontainer_directory = repo_contents.find { |f| f.type == "dir" && f.name == ".devcontainer" }
      end

      def fetch_config_and_lockfile_from(directory)
        files = []

        config_name = Utils.expected_config_basename(directory)
        config_file = fetch_file_if_present(File.join(directory, config_name))
        return files unless config_file

        files << config_file

        lockfile_name = Utils.expected_lockfile_name(File.basename(config_file.name))
        lockfile = fetch_support_file(File.join(directory, lockfile_name))
        files << lockfile if lockfile

        files
      end
    end
  end
end

Dependabot::FileFetchers.register("devcontainers", Dependabot::Devcontainers::FileFetcher)

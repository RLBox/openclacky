# frozen_string_literal: true

require "fileutils"

module Clacky
  module DefaultExtensions
    module Codex
      # Creates an isolated CODEX_HOME and reuses only a securely validated
      # file-backed login. No other source-home content is copied or linked.
      class CodexHome
        class Error < StandardError; end
        class UnsafeManagedHomeError < Error; end

        Result = Struct.new(
          :managed_home,
          :auth_reused,
          :auth_reason,
          keyword_init: true
        )

        def initialize(managed_home: nil, source_home: nil, source_auth_path: nil,
                       platform: RUBY_PLATFORM, current_uid: Process.uid,
                       symlink_creator: nil)
          @managed_home = File.expand_path(
            managed_home || File.join(Clacky::ExtensionLoader.data_dir_for("codex"), "codex-home")
          )
          @source_home = File.expand_path(source_home || default_source_home)
          @source_auth_path = File.expand_path(
            source_auth_path || File.join(@source_home, "auth.json")
          )
          @platform = platform.to_s
          @current_uid = current_uid
          @symlink_creator = symlink_creator || File.method(:symlink)
        end

        def prepare
          prepare_managed_home!

          return without_auth_reuse("unsupported_platform") if windows?

          source_path, rejection = validated_source_auth
          return without_auth_reuse(rejection) if rejection

          destination = managed_auth_path
          if File.symlink?(destination)
            return reused_result if symlink_targets?(destination, source_path)
            File.unlink(destination)
          elsif path_entry?(destination)
            return result(false, "managed_auth_occupied")
          end

          begin
            @symlink_creator.call(source_path, destination)
            unless File.symlink?(destination) && symlink_targets?(destination, source_path)
              File.unlink(destination) if path_entry?(destination)
              return result(false, "symlink_failed")
            end
          rescue NotImplementedError, SystemCallError
            File.unlink(destination) if File.symlink?(destination)
            return result(false, "symlink_failed")
          end

          reused_result
        end

        private def default_source_home
          configured = ENV["CODEX_HOME"].to_s.strip
          configured.empty? ? File.join(Dir.home, ".codex") : configured
        end

        private def prepare_managed_home!
          if File.symlink?(@managed_home)
            raise UnsafeManagedHomeError, "managed Codex home must not be a symlink"
          end
          if File.exist?(@managed_home) && !File.directory?(@managed_home)
            raise UnsafeManagedHomeError, "managed Codex home must be a directory"
          end

          FileUtils.mkdir_p(@managed_home, mode: 0o700)
          FileUtils.chmod(0o700, @managed_home)
        end

        private def validated_source_auth
          return [nil, "source_home_missing"] unless File.directory?(@source_home)
          return [nil, "source_missing"] unless path_entry?(@source_auth_path)
          return [nil, "source_symlink"] if File.symlink?(@source_auth_path)
          return [nil, "source_not_regular"] unless File.file?(@source_auth_path)

          source_home_real = File.realpath(@source_home)
          source_real = File.realpath(@source_auth_path)
          unless inside_directory?(source_real, source_home_real)
            return [nil, "outside_source_home"]
          end

          stat = File.stat(source_real)
          if !@current_uid.nil? && stat.respond_to?(:uid) && stat.uid != @current_uid
            return [nil, "wrong_owner"]
          end
          return [nil, "insecure_permissions"] unless (stat.mode & 0o077).zero?

          [source_real, nil]
        rescue SystemCallError
          [nil, "source_unavailable"]
        end

        private def inside_directory?(path, directory)
          path.start_with?(directory.chomp(File::SEPARATOR) + File::SEPARATOR)
        end

        private def windows?
          @platform.match?(/mswin|mingw|cygwin/i)
        end

        private def managed_auth_path
          File.join(@managed_home, "auth.json")
        end

        private def symlink_targets?(link, source)
          File.realpath(link) == File.realpath(source)
        rescue SystemCallError
          false
        end

        private def path_entry?(path)
          File.exist?(path) || File.symlink?(path)
        end

        private def without_auth_reuse(reason)
          destination = managed_auth_path
          File.unlink(destination) if File.symlink?(destination)
          result(false, reason)
        end

        private def reused_result
          result(true, "reused")
        end

        private def result(auth_reused, auth_reason)
          Result.new(
            managed_home: @managed_home,
            auth_reused: auth_reused,
            auth_reason: auth_reason
          )
        end
      end
    end
  end
end

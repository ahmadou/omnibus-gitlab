require 'omnibus'
require 'net/http'
require 'json'

require_relative '../build_iteration'
require_relative 'check'
require_relative 'image'

module Build
  class Info
    class << self
      def package
        return "gitlab-ee" if Check.is_ee?

        "gitlab-ce"
      end

      # For nightly builds we fetch all GitLab components from master branch
      # If there was no change inside of the omnibus-gitlab repository, the
      # package version will remain the same but contents of the package will be
      # different.
      # To resolve this, we append a PIPELINE_ID to change the name of the package
      def semver_version
        if Build::Check.on_tag?
          # timestamp is disabled in omnibus configuration
          Omnibus.load_configuration('omnibus.rb')
          Omnibus::BuildVersion.semver
        else
          latest_git_tag = Info.latest_tag.strip
          latest_version = latest_git_tag[0, latest_git_tag.match("[+]").begin(0)]
          commit_sha_raw = ENV['CI_COMMIT_SHA'] || `git rev-parse HEAD`.strip
          commit_sha = commit_sha_raw[0, 8]
          if Build::Check.add_nightly_tag?
            "#{latest_version}+rnightly.#{ENV['CI_PIPELINE_ID']}.#{commit_sha}"
          else
            "#{latest_version}+rfbranch.#{ENV['CI_PIPELINE_ID']}.#{commit_sha}"
          end
        end
      end

      def release_version
        semver = Info.semver_version
        "#{semver}-#{Gitlab::BuildIteration.new.build_iteration}"
      end

      # TODO, merge latest_tag with latest_stable_tag
      # TODO, add tests, needs a repo clone
      def latest_tag
        `git -c versionsort.prereleaseSuffix=rc tag -l '#{Info.tag_match_pattern}' --sort=-v:refname | head -1`
      end

      def latest_stable_tag(level: 1)
        # Level decides tag at which position you want. Level one gives you
        # latest stable tag, two gives you the one just before it and so on.
        `git -c versionsort.prereleaseSuffix=rc tag -l '#{Info.tag_match_pattern}' --sort=-v:refname | awk '!/rc/' | head -#{level}`.split("\n").last
      end

      def docker_tag
        Info.release_version.tr('+', '-')
      end

      def gitlab_version
        # Get the branch/version/commit of GitLab CE/EE repo against which package
        # is built. If GITLAB_VERSION variable is specified, as in triggered builds,
        # we use that. Else, we use the value in VERSION file.

        if ENV['GITLAB_VERSION'].nil? || ENV['GITLAB_VERSION'].empty?
          File.read('VERSION').strip
        else
          ENV['GITLAB_VERSION']
        end
      end

      def previous_version
        # Get the second latest git tag
        previous_tag = Info.latest_stable_tag(level: 2)
        previous_tag.tr("+", "-")
      end

      def gitlab_rails_repo
        # For normal builds, QA build happens from the gitlab repositories in dev.
        # For triggered builds, they are not available and their gitlab.com mirrors
        # have to be used.

        if ENV['ALTERNATIVE_SOURCES'].to_s == "true"
          domain = "https://gitlab.com/gitlab-org"
          project = package
        else
          domain = "git@dev.gitlab.org:gitlab"

          # GitLab CE repo in dev.gitlab.org is named gitlabhq. So we need to
          # identify gitlabhq from gitlab-ce. Fortunately gitlab-ee does not have
          # this problem.
          project = package == "gitlab-ce" ? "gitlabhq" : "gitlab-ee"
        end

        "#{domain}/#{project}.git"
      end

      def edition
        Info.package.gsub("gitlab-", "").strip # 'ee' or 'ce'
      end

      def release_bucket
        # Tag builds are releases and they get pushed to a specific S3 bucket
        # whereas regular branch builds use a separate one
        Check.on_tag? ? "downloads-packages" : "omnibus-builds"
      end

      def log_level
        if ENV['BUILD_LOG_LEVEL'] && !ENV['BUILD_LOG_LEVEL'].empty?
          ENV['BUILD_LOG_LEVEL']
        else
          'info'
        end
      end

      # Fetch the package from an S3 bucket
      def package_download_url
        package_filename_url_safe = Info.release_version.gsub("+", "%2B")
        "https://#{Info.release_bucket}.s3.amazonaws.com/ubuntu-xenial/#{Info.package}_#{package_filename_url_safe}_amd64.deb"
      end

      def fetch_artifact_url(project_id, pipeline_id)
        uri = URI("https://gitlab.com/api/v4/projects/#{project_id}/pipelines/#{pipeline_id}/jobs")
        req = Net::HTTP::Get.new(uri)
        req['PRIVATE-TOKEN'] = ENV["TRIGGER_PRIVATE_TOKEN"]
        http = Net::HTTP.new(uri.hostname, uri.port)
        http.use_ssl = true
        res = http.request(req)
        output = JSON.parse(res.body)
        output.find { |job| job['name'] == 'Trigger:package' }['id']
      end

      def triggered_build_package_url
        project_id = ENV['CI_PROJECT_ID']
        pipeline_id = ENV['CI_PIPELINE_ID']
        return unless project_id && !project_id.empty? && pipeline_id && !pipeline_id.empty?

        id = fetch_artifact_url(project_id, pipeline_id)
        "#{ENV['CI_PROJECT_URL']}/builds/#{id}/artifacts/raw/pkg/ubuntu-xenial/gitlab.deb"
      end

      def tag_match_pattern
        return '*[+.]ee.*' if Check.is_ee?

        '*[+.]ce.*'
      end

      def release_file_contents
        repo = ENV['PACKAGECLOUD_REPO'] # Target repository
        token = ENV['TRIGGER_PRIVATE_TOKEN'] # Token used for triggering a build

        download_url = if token && !token.empty?
                         Info.triggered_build_package_url
                       else
                         Info.package_download_url
                       end
        contents = []
        contents << "PACKAGECLOUD_REPO=#{repo.chomp}\n" if repo && !repo.empty?
        contents << "RELEASE_PACKAGE=#{Info.package}\n"
        contents << "RELEASE_VERSION=#{Info.release_version}\n"
        contents << "DOWNLOAD_URL=#{download_url}\n" if download_url
        contents << "TRIGGER_PRIVATE_TOKEN=#{token.chomp}\n" if token && !token.empty?
        contents.join
      end
    end
  end
end

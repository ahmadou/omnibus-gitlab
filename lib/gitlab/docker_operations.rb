require 'docker'

class DockerOperations
  def self.set_timeout
    timeout = ENV['DOCKER_TIMEOUT'] || 1200
    Docker.options = { read_timeout: timeout, write_timeout: timeout }
  end

  def self.build(location, image, tag)
    set_timeout
    Docker::Image.build_from_dir(location.to_s, { t: "#{image}:#{tag}", pull: true }) do |chunk|
      if (log = JSON.parse(chunk)) && log.key?("stream")
        puts log["stream"]
      end
    end
  end

  def self.authenticate(username = ENV['DOCKERHUB_USERNAME'], password = ENV['DOCKERHUB_PASSWORD'], serveraddress = "")
    Docker.authenticate!(username: username, password: password, serveraddress: serveraddress)
  end

  def self.get(namespace, tag)
    set_timeout
    Docker::Image.get("#{namespace}:#{tag}")
  end

  def self.push(namespace, tag)
    set_timeout
    image = get(namespace, tag)
    image.push(Docker.creds, repo_tag: "#{namespace}:#{tag}") do |chunk|
      puts chunk
    end
  end

  def self.tag(initial_namespace, new_namespace, initial_tag, new_tag)
    set_timeout
    image = get(initial_namespace, initial_tag)
    image.tag(repo: new_namespace, tag: new_tag, force: true)
  end

  # namespace - registry project. Can be one of:
  # 1. gitlab/gitlab-{ce,ee}
  # 2. gitlab/gitlab-{ce,ee}-qa
  # 3. omnibus-gitlab/gitlab-{ce,ee}
  #
  # initial_tag - specifies the tag used while building the image. Can be one of:
  # 1. latest - for GitLab images
  # 2. ce-latest or ee-latest - for GitLab QA images
  # 3. any other valid docker tag
  #
  # new_tag - specifies the new tag for the existing image
  def self.tag_and_push(initial_namespace, new_namespace, initial_tag, new_tag)
    tag(initial_namespace, new_namespace, initial_tag, new_tag)
    push(new_namespace, new_tag)
  end
end

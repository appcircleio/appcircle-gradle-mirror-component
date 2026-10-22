require 'colored'
require 'fileutils'
require 'uri'

INIT_SCRIPT_NAME = 'appcircle-mirror.gradle'.freeze

def get_env_variable(key)
  ENV[key].nil? || ENV[key] == '' ? nil : ENV[key]
end

def abort_with1(message)
  puts "@@[error] #{message}".red
  exit 1
end

def get_info_msg(message)
  puts " \n#{message.green}"
end

def get_warning_msg(message)
  puts "@@[warning] #{message}".yellow
end

# The URL without user info, for the log.
def shown_url(url)
  url.sub(%r{\A(https?://)[^/@]*@}, '\1')
end

# The Gradle pair if any part of it is set, otherwise the pair shared by all mirror steps.
# A pair is never mixed with the other one, and a half-set pair is an error.
def mirror_credentials
  [%w[AC_MIRROR_GRADLE_USERNAME AC_MIRROR_GRADLE_PASSWORD], %w[AC_MIRROR_USERNAME AC_MIRROR_PASSWORD]].each do |user_key, password_key|
    user = get_env_variable(user_key)
    password = get_env_variable(password_key)
    next if user.nil? && password.nil?

    abort_with1("#{user_key} and #{password_key} must be set together.") if user.nil? || password.nil?
    abort_with1("#{user_key} and #{password_key} must not contain line breaks.") if "#{user}#{password}".match?(/[\r\n]/)
    if "#{user}#{password}".include?('\\')
      get_warning_msg("#{user_key} or #{password_key} contains a backslash. Older gradlew scripts can change it before the wrapper reads it; if the wrapper download fails with 401, regenerate the wrapper with a current Gradle version (gradle wrapper).")
    end
    return [user_key, user, password]
  end
  [nil, nil, nil]
end

# The init script holds no URL and no secret, so writing it again on every run gives the same file.
# Written to a temporary file and renamed, so a build running at the same time never reads half a file.
def install_init_script(gradle_home)
  init_dir = File.join(gradle_home, 'init.d')
  FileUtils.mkdir_p(init_dir)
  path = File.join(init_dir, INIT_SCRIPT_NAME)
  temp = "#{path}.#{Process.pid}.tmp"
  FileUtils.cp(File.join(__dir__, INIT_SCRIPT_NAME), temp)
  File.rename(temp, path)
  path
end

# One argument for the shell word splitting that gradlew applies to GRADLE_OPTS (xargs): single quotes,
# with every single quote written as '\''.
def gradlew_quote(value)
  "'#{value.gsub("'", %q('\\\\''))}'"
end

# Values for the later steps of this build only (nothing is written into the Gradle user home, so a runner
# that keeps it between builds does not keep a password):
# - skipDependencyChecks: the Flutter Gradle plugin's dependency checker declares its own repositories,
#   which an init script cannot reach.
# - The wrapper credentials: the wrapper downloads the distribution before any init script runs and reads
#   them as system properties.
# - The mirror URL and the chosen credentials under the Gradle names, for the init script: step inputs reach
#   only this step, so a value typed into the input (not taken from an environment variable group) would
#   otherwise never reach the Gradle builds of the later steps.
def export_for_later_steps(mirror, user, password)
  env_file = get_env_variable('AC_ENV_FILE_PATH')
  abort_with1('AC_ENV_FILE_PATH is not set.') if env_file.nil?

  lines = ['ORG_GRADLE_PROJECT_skipDependencyChecks=true', "AC_MIRROR_GRADLE=#{mirror}"]
  if user
    lines += ["AC_MIRROR_GRADLE_USERNAME=#{user}", "AC_MIRROR_GRADLE_PASSWORD=#{password}"]
    wrapper = "-Dgradle.wrapperUser=#{gradlew_quote(user)} -Dgradle.wrapperPassword=#{gradlew_quote(password)}"
    lines << "GRADLE_OPTS=#{[get_env_variable('GRADLE_OPTS'), wrapper].compact.join(' ')}"
  end
  File.open(env_file, 'a') { |f| lines.each { |line| f.puts(line) } }
end

WRAPPER_MODES = %w[update fail warn].freeze
PUBLIC_DISTRIBUTION_HOST = 'services.gradle.org'.freeze

# The wrapper downloads Gradle before any init script runs, so its distributionUrl in the project decides where
# Gradle comes from. Checks every wrapper of the cloned project and, depending on the mode, points the ones that
# use services.gradle.org at the mirror (update, the default), stops the build (fail) or only warns (warn).
def check_wrappers(mode, distribution_mirror, proxy_host)
  repository_dir = get_env_variable('AC_REPOSITORY_DIR')
  unless repository_dir && Dir.exist?(repository_dir) && !Dir.empty?(repository_dir)
    get_warning_msg('The repository is not cloned yet, so the Gradle wrapper check is skipped. Place the Gradle Mirror step after Git Clone.')
    return
  end

  wrappers = Dir.glob(File.join(repository_dir, '**', 'gradle', 'wrapper', 'gradle-wrapper.properties'))
                .reject { |path| path.match?(%r{/(node_modules|build|\.git|Pods)/}) }
  public_wrappers = []
  counts = Hash.new(0)
  wrappers.each do |wrapper|
    lines = File.readlines(wrapper, chomp: true)
    index = lines.index { |line| line.start_with?('distributionUrl=') }
    next if index.nil?

    url = lines[index].delete_prefix('distributionUrl=').gsub('\\:', ':')
    relative = wrapper.delete_prefix("#{repository_dir}/")
    counts[:checked] += 1
    host = URI(url).host
    if host == proxy_host
      counts[:proxy] += 1
      puts "Gradle wrapper: #{relative} already uses the artifact proxy (#{shown_url(url)}), no change"
      next
    elsif host != PUBLIC_DISTRIBUTION_HOST
      counts[:other] += 1
      puts "Gradle wrapper: #{relative} uses #{shown_url(url)}, not #{PUBLIC_DISTRIBUTION_HOST}, no change"
      next
    end

    if mode == 'update' && distribution_mirror
      new_url = "#{distribution_mirror}#{URI(url).path.delete_prefix('/')}"
      lines[index] = "distributionUrl=#{new_url.sub('://', '\\://')}"
      temp = "#{wrapper}.#{Process.pid}.tmp"
      File.write(temp, "#{lines.join("\n")}\n")
      File.rename(temp, wrapper)
      counts[:updated] += 1
      puts "Gradle wrapper: #{relative} updated: #{url} -> #{shown_url(new_url)} (cloned copy only)"
    else
      counts[:public] += 1
      puts "Gradle wrapper: #{relative} downloads Gradle from #{PUBLIC_DISTRIBUTION_HOST} (#{shown_url(url)})"
      public_wrappers << relative
    end
  end
  summary = "Gradle wrapper (mode: #{mode}): #{counts[:checked]} #{counts[:checked] == 1 ? 'wrapper' : 'wrappers'} checked: #{counts[:proxy]} already on the proxy, #{counts[:updated]} updated, #{counts[:other]} on another host, #{counts[:public]} still on #{PUBLIC_DISTRIBUTION_HOST}"
  summary = "Gradle wrapper (mode: #{mode}): no gradle-wrapper.properties in the project" if counts[:checked].zero?
  puts summary
  return if public_wrappers.empty?

  if mode == 'update'
    abort_with1("#{public_wrappers.join(', ')} downloads Gradle from #{PUBLIC_DISTRIBUTION_HOST}, and AC_MIRROR_GRADLE_DISTRIBUTION is empty. Set the Gradle Distribution Mirror URL, or point distributionUrl at your artifact proxy in the project.")
  end
  message = "#{public_wrappers.join(', ')} downloads Gradle from #{PUBLIC_DISTRIBUTION_HOST}. Point distributionUrl at your artifact proxy in the project, or set the Gradle Wrapper input to update."
  mode == 'fail' ? abort_with1(message) : get_warning_msg(message)
end

mirror = get_env_variable('AC_MIRROR_GRADLE')
if mirror.nil?
  puts 'AC_MIRROR_GRADLE is empty: Gradle uses the repositories of the project.'
  exit 0
end
abort_with1('AC_MIRROR_GRADLE must be an http or https URL.') unless mirror.match?(%r{\Ahttps?://\S+\z})

credential_source, user, password = mirror_credentials
gradle_home = get_env_variable('GRADLE_USER_HOME') || File.join(Dir.home, '.gradle')

init_script = install_init_script(gradle_home)
export_for_later_steps(mirror, user, password)

puts "Gradle Mirror: repositories -> #{shown_url(mirror)} (credentials: #{credential_source || 'none'})"
puts "Gradle Mirror: init script #{init_script}"
wrapper_mode = (get_env_variable('AC_MIRROR_GRADLE_WRAPPER') || 'update').downcase
abort_with1("AC_MIRROR_GRADLE_WRAPPER must be one of #{WRAPPER_MODES.join(', ')}.") unless WRAPPER_MODES.include?(wrapper_mode)
distribution_mirror = get_env_variable('AC_MIRROR_GRADLE_DISTRIBUTION')
if distribution_mirror
  abort_with1('AC_MIRROR_GRADLE_DISTRIBUTION must be an http or https URL.') unless distribution_mirror.match?(%r{\Ahttps?://\S+\z})
  distribution_mirror += '/' unless distribution_mirror.end_with?('/')
end
proxy_host = URI(distribution_mirror || mirror).host
check_wrappers(wrapper_mode, distribution_mirror, proxy_host)
get_info_msg('Gradle Mirror is configured.')

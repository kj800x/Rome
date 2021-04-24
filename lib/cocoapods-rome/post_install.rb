require 'fourflusher'

PLATFORMS = { 'iphonesimulator' => 'iOS',
              'appletvsimulator' => 'tvOS',
              'watchsimulator' => 'watchOS' }

def build_for_iosish_platform(sandbox, build_dir, target, device, simulator, configuration)
  deployment_target = target.platform_deployment_target
  target_label = target.cocoapods_target_label

  Pod::UI.puts "Building #{configuration} #{target} for device"
  xcodebuild(sandbox, target_label, device, deployment_target, configuration)
  Pod::UI.puts "Building #{configuration} #{target} for simulator"
  xcodebuild(sandbox, target_label, simulator, deployment_target, configuration)

  Pod::UI.puts target.specs

  spec_names = target.specs.map { |spec| [spec.root.name, spec.root.module_name] }.uniq
  spec_names.each do |root_name, module_name|
    executable_path = "#{build_dir}/#{root_name}.xcframework"
    device_lib = "#{build_dir}/#{configuration}-#{device}/#{root_name}/#{module_name}.framework"
    device_framework_lib = File.dirname(device_lib)
    simulator_lib = "#{build_dir}/#{configuration}-#{simulator}/#{root_name}/#{module_name}.framework"

    next unless File.directory?(device_lib) && File.directory?(simulator_lib)

    Pod::UI.puts "Creating the xcframework for #{root_name}"
    Pod::UI.puts "Running: xcodebuild -create-xcframework -framework #{device_lib} -framework #{simulator_lib} -output #{executable_path}"
    Pod::UI.puts "Expectd: xcodebuild -create-xcframework -framework /Users/kjohnson/src/HubSpotReactNativeCore/ios/build/Debug-iphoneos/React-Core/React.framework -framework /Users/kjohnson/src/HubSpotReactNativeCore/ios/build/Debug-iphonesimulator/React-Core/React.framework -output React-Core.xcframework"

    xframework_merge_log = `xcodebuild -create-xcframework -framework #{device_lib} -framework #{simulator_lib} -output #{executable_path}`
    Pod::UI.puts xframework_merge_log unless File.exist?(executable_path)
  end
end

def xcodebuild(sandbox, target, sdk='macosx', deployment_target=nil, configuration='Debug', build_settings=nil)
  args = %W(-project #{sandbox.project_path.realdirpath} -scheme #{target} -configuration #{configuration} -sdk #{sdk})
  if build_settings
    args.append(build_settings)
  end
  platform = PLATFORMS[sdk]
  args += Fourflusher::SimControl.new.destination(:oldest, platform, deployment_target) unless platform.nil?
  Pod::UI.puts args
  Pod::Executable.execute_command 'xcodebuild', args, true
end

def enable_debug_information(project_path, configuration)
  project = Xcodeproj::Project.open(project_path)
  project.targets.each do |target|
    config = target.build_configurations.find { |config| config.name.eql? configuration }
    config.build_settings['DEBUG_INFORMATION_FORMAT'] = 'dwarf-with-dsym'
    config.build_settings['ONLY_ACTIVE_ARCH'] = 'NO'
  end
  project.save
end

def configure_build_options(project_path, configuration)
  project = Xcodeproj::Project.open(project_path)
  project.targets.each do |target|
    config = target.build_configurations.find { |config| config.name.eql? configuration }
    config.build_settings['SKIP_INSTALL'] = 'NO'
    config.build_settings['BUILD_LIBRARIES_FOR_DISTRIBUTION'] = 'YES'
  end
  project.save
end

def copy_dsym_files(dsym_destination, configuration)
  # dsym_destination.rmtree if dsym_destination.directory?
  platforms = ['iphoneos', 'iphonesimulator']
  platforms.each do |platform|
    dsym = Pathname.glob("build/#{configuration}-#{platform}/**/*.dSYM")
    dsym.each do |dsym|
      destination = dsym_destination + platform
      FileUtils.mkdir_p destination
      FileUtils.cp_r dsym, destination, :remove_destination => true
    end
  end
end

def buildForConfiguration(configuration, enable_dsym, sandbox_root, sandbox, installer_context)
  enable_debug_information(sandbox.project_path, configuration) if enable_dsym
  configure_build_options(sandbox.project_path, configuration)

  build_dir = sandbox_root.parent + 'build'
  destination = sandbox_root.parent + "Rome/#{configuration}"

  Pod::UI.puts "Building #{configuration} frameworks"

  build_dir.rmtree if build_dir.directory?
  targets = installer_context.umbrella_targets.select { |t| t.specs.any? }
  targets.each do |target|
    case target.platform_name
    when :ios then build_for_iosish_platform(sandbox, build_dir, target, 'iphoneos', 'iphonesimulator', configuration)
    when :osx then xcodebuild(sandbox, target.cocoapods_target_label, configuration)
    when :tvos then build_for_iosish_platform(sandbox, build_dir, target, 'appletvos', 'appletvsimulator', configuration)
    when :watchos then build_for_iosish_platform(sandbox, build_dir, target, 'watchos', 'watchsimulator', configuration)
    else raise "Unknown platform '#{target.platform_name}'" end
  end

  raise Pod::Informative, 'The build directory was not found in the expected location.' unless build_dir.directory?

  # Make sure the device target overwrites anything in the simulator build, otherwise iTunesConnect
  # can get upset about Info.plist containing references to the simulator SDK
  frameworks = Pathname.glob("build/*/*/*.xcframework").reject { |f| f.to_s =~ /Pods[^.]+\.framework/ }
  frameworks += Pathname.glob("build/*.xcframework").reject { |f| f.to_s =~ /Pods[^.]+\.framework/ }

  Pod::UI.puts frameworks

  resources = []

  Pod::UI.puts "Built #{frameworks.count} #{'frameworks'.pluralize(frameworks.count)}"

  installer_context.umbrella_targets.each do |umbrella|
    umbrella.specs.each do |spec|
      consumer = spec.consumer(umbrella.platform_name)
      file_accessor = Pod::Sandbox::FileAccessor.new(sandbox.pod_dir(spec.root.name), consumer)
      frameworks += file_accessor.vendored_libraries
      frameworks += file_accessor.vendored_frameworks
      resources += file_accessor.resources
    end
  end
  frameworks.uniq!
  resources.uniq!

  Pod::UI.puts "Copying #{frameworks.count} #{'frameworks'.pluralize(frameworks.count)} " \
    "to `#{destination.relative_path_from Pathname.pwd}`"

  FileUtils.mkdir_p destination
  (frameworks + resources).each do |file|
    FileUtils.cp_r file, destination, :remove_destination => true
  end

  copy_dsym_files(sandbox_root.parent + 'dSYM', configuration) if enable_dsym

  build_dir.rmtree if build_dir.directory?
end

Pod::HooksManager.register('cocoapods-rome', :post_install) do |installer_context, user_options|
  enable_dsym = user_options.fetch('dsym', true)
  configuration = user_options.fetch('configuration', 'Debug')
  if user_options["pre_compile"]
    user_options["pre_compile"].call(installer_context)
  end

  sandbox_root = Pathname(installer_context.sandbox_root)
  sandbox = Pod::Sandbox.new(sandbox_root)

  destination = sandbox_root.parent + 'Rome'
  destination.rmtree if destination.directory?

  if configuration == "Both"
    buildForConfiguration("Release", enable_dsym, sandbox_root, sandbox, installer_context)
    buildForConfiguration("Debug", enable_dsym, sandbox_root, sandbox, installer_context)
  else
    buildForConfiguration(configuration, enable_dsym, sandbox_root, sandbox, installer_context)
  end

  if user_options["post_compile"]
    user_options["post_compile"].call(installer_context)
  end
end

# Cookbook:: veeam
# Resource:: console
#
# Author:: Jeremy Goodrum
# Email:: chef@exospheredata.com
#
# Version:: 1.0.0
# Date:: 2018-04-29
#
# Copyright:: (c) 2020 Exosphere Data LLC, All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

default_action :install

property :package_name, String
property :share_path, String

property :package_url, String
property :package_checksum, String

property :accept_eula, [true, false], required: true
property :install_dir, String

property :version, String, required: true
property :keep_media, [true, false], default: false

# We need to include the windows helpers to keep things dry
::Chef::Provider.send(:include, Windows::Helper)
::Chef::Provider.send(:include, Veeam::Helper)

action :install do
  check_os_version(node)

  # We will use the Windows Helper 'is_package_installed?' to see if the Console is installed.  If it is installed, then
  # we should report no change back.  By returning 'false', Chef will report that the resource is up-to-date.
  if is_package_installed?('Veeam Backup & Replication Console')

    # => If the build version and the installed version match then return up-to-date
    return false if Gem::Version.new(new_resource.version) <= Gem::Version.new(find_current_veeam_version('Veeam Backup & Replication Console'))

    # => Previous versions are upgraded through update files and therefore, this is up-to-date
    return false if Gem::Version.new(new_resource.version) <= Gem::Version.new('9.5.3.0')

    # => An Upgrade is available and should be started
    Chef::Log.info('New Console Upgrade is available')
  end

  # We need to verify that .NET Framework 4.5.2 or higher has been installed on the machine
  raise 'The Veeam Backup and Recovery Server requires that Microsoft .NET Framework 4.5.2 or higher be installed.  Please install the Veeam pre-requisites' if find_current_dotnet < 379893

  # The EULA must be explicitly accepted.
  raise ArgumentError, 'The Veeam Backup and Recovery EULA must be accepted.  Please set the node attribute [\'veeam\'][\'console\'][\'accept_eula\'] to \'true\' ' if new_resource.accept_eula.nil? || new_resource.accept_eula == false

  package_save_dir = win_clean_path(::File.join(::Chef::Config[:file_cache_path], 'package'))

  # This will only create the directory if it does not exist which is likely the case if we have
  # never performed a remote_file install.
  directory package_save_dir do
    action :create
  end

  # Call the Veeam::Helper to find the correct URL based on the version of the Veeam Backup and Recovery edition passed
  # as an attribute.
  unless new_resource.package_url
    new_resource.package_url = find_package_url(new_resource.version)
    new_resource.package_checksum = find_package_checksum(new_resource.version)
    Chef::Log.info(new_resource.package_url)
  end

  # Halt this process now.  There is no URL for the package.
  raise ArgumentError, 'You must provide a package URL or choose a valid version' unless new_resource.package_url

  # Since we are passing a URL, it is important that we handle the pull of the file as well as extraction.
  # We likely will receive an ISO but it is possible that we will have a ZIP or other compressed file type.
  # This is easy to handle as long as we add a method to check for the file base type.

  Chef::Log.debug('Downloading Veeam Backup and Recovery software via URL')
  package_name = new_resource.package_url.split('/').last
  installer_file_name = win_clean_path(::File.join(package_save_dir, package_name))
  iso_installer(installer_file_name, new_resource)

  ruby_block 'Install the Backup console application' do
    block do
      Chef::Log.debug 'Installing Veeam Backup and Recovery console'
      install_media_path = get_media_installer_location(installer_file_name)
      perform_console_install(install_media_path)
    end
    action :run
  end

  # Dismount the ISO if it is mounted
  unmount_installer(installer_file_name)

  # If the 'keep_media' property is True, we should report our success but skip the file deletion code below.
  return if new_resource.keep_media

  # Since the property 'keep_media' was set to false, we will need to remove it

  # We will want to remove the tmp downloaded file later to save space
  file installer_file_name do
    backup false
    action :delete
  end
end

action_class do
  def perform_console_install(install_media_path)
    Chef::Log.debug 'Installing Veeam Backup console service... begin'
    # In this case, we have many possible combinations of extra arugments that would need to be passed to the installer.
    # The process will create a usable string formatted to support those optional arguments. It seemed safer to attempt
    # to do all of this work inside of Ruby rather than the back and forth with PowerShell scripts. Note that each of these
    # resources are considered optional and will only be set if sent to use by the resource block.
    xtra_arguments = ''
    xtra_arguments.concat(" ACCEPTEULA=\"#{new_resource.accept_eula ? 'YES' : 'NO'}\" ") unless new_resource.accept_eula.nil?
    xtra_arguments.concat(" INSTALLDIR=\"#{new_resource.install_dir} \" ") unless new_resource.install_dir.nil?
    xtra_arguments.concat(' ACCEPT_THIRDPARTY_LICENSES="1" ')

    cmd_str = <<-EOH
      $veeam_backup_console_installer = ( "#{install_media_path}\\Backup\\Shell.x64.msi")
      Write-Host (' /qn /i ' + $veeam_backup_console_installer + ' #{xtra_arguments}')
      $output = (Start-Process -FilePath "msiexec.exe" -ArgumentList $(' /qn /i ' + $veeam_backup_console_installer + ' #{xtra_arguments}') -Wait -Passthru -ErrorAction Stop)
      if ( $output.ExitCode -ne 0){
        throw ("The install failed with ExitCode [{0}].  The package is {1}" -f $output.ExitCode, $veeam_backup_console_installer )
      }
    EOH
    validate_powershell_out(cmd_str)
    Chef::Log.debug 'Installing Veeam Backup console service... success'
  end
end

$ErrorActionPreference = 'Stop'
Start-Transcript -Path C:\Windows\Temp\post-install.log

# Find a file on any CD drive (drive letters vary)
function Find-OnCd([string]$Name) {
    $cds = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=5' | ForEach-Object { $_.DeviceID + '\' }
    foreach ($cd in $cds) {
        $hit = Get-ChildItem -Path $cd -Filter $Name -Recurse -Depth 3 -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    throw "Could not find $Name on any CD drive"
}

# Install an MSI and stop everything if it fails
function Install-Msi([string]$Msi, [string]$Extra = '') {
    $log = "C:\Windows\Temp\$(Split-Path $Msi -Leaf).log"
    Write-Output "Installing $Msi ..."
    $p = Start-Process msiexec.exe -ArgumentList "/i `"$Msi`" /qn /norestart /l*v `"$log`" $Extra" -Wait -PassThru
    if ($p.ExitCode -notin 0, 3010) { throw "$Msi failed with exit code $($p.ExitCode) - see $log" }
}

# 1. QEMU guest agent, from the virtio-win CD
Install-Msi (Find-OnCd 'qemu-ga-x86_64.msi')
Get-Service QEMU-GA | Format-Table Name, Status, StartType -AutoSize

# 2. Cloudbase-Init, downloaded (the VM has outbound internet via the pod network)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$cbi = 'C:\Windows\Temp\CloudbaseInitSetup_Stable_x64.msi'
Invoke-WebRequest -UseBasicParsing -OutFile $cbi `
    -Uri 'https://www.cloudbase.it/downloads/CloudbaseInitSetup_Stable_x64.msi'
Install-Msi $cbi 'RUN_SERVICE_AS_LOCAL_SYSTEM=1 LOGGINGSERIALPORTNAME=COM1'
Stop-Service cloudbase-init -ErrorAction SilentlyContinue   # only run on clones
Set-Service cloudbase-init -StartupType Manual   # started by SetupComplete.cmd after setup
New-Item -ItemType Directory -Force -Path C:\Windows\Setup\Scripts | Out-Null
Set-Content -Encoding ASCII -Path C:\Windows\Setup\Scripts\SetupComplete.cmd -Value "sc config cloudbase-init start= auto`r`nnet start cloudbase-init"

# 3. Cloudbase-Init config (same as cloudbase-init/cloudbase-init.conf in the local repo)
$conf = @'
[DEFAULT]
metadata_services=cloudbaseinit.metadata.services.nocloudservice.NoCloudConfigDriveService
plugins=cloudbaseinit.plugins.common.mtu.MTUPlugin,
        cloudbaseinit.plugins.common.sethostname.SetHostNamePlugin,
        cloudbaseinit.plugins.common.networkconfig.NetworkConfigPlugin,
        cloudbaseinit.plugins.windows.extendvolumes.ExtendVolumesPlugin,
        cloudbaseinit.plugins.common.userdata.UserDataPlugin,
        cloudbaseinit.plugins.common.localscripts.LocalScriptsPlugin
allow_reboot=true
stop_service_on_exit=false
bsdtar_path=C:\Program Files\Cloudbase Solutions\Cloudbase-Init\bin\bsdtar.exe
mtools_path=C:\Program Files\Cloudbase Solutions\Cloudbase-Init\bin\
local_scripts_path=C:\Program Files\Cloudbase Solutions\Cloudbase-Init\LocalScripts\
verbose=true
debug=true
logdir=C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\
logfile=cloudbase-init.log
default_log_levels=comtypes=INFO,suds=INFO,iso8601=WARN,requests=WARN
logging_serial_port_settings=COM1,115200,N,8
'@
Set-Content -Encoding ASCII -Value $conf `
    -Path 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\cloudbase-init.conf'

# 4. Clone answer file (same as unattend-clone.xml in the local repo)
$clone = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="generalize">
    <component name="Microsoft-Windows-PnpSysprep" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <PersistAllDeviceInstalls>true</PersistAllDeviceInstalls>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>*</ComputerName>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-GB</SystemLocale>
      <UserLocale>en-GB</UserLocale>
      <UILanguage>en-US</UILanguage>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <AdministratorPassword>
          <Value>Password123!</Value>
          <PlainText>true</PlainText>
        </AdministratorPassword>
      </UserAccounts>
      <AutoLogon>
        <Password>
          <Value>Password123!</Value>
          <PlainText>true</PlainText>
        </Password>
        <Enabled>true</Enabled>
        <LogonCount>1</LogonCount>
        <Username>Administrator</Username>
      </AutoLogon>
    </component>
  </settings>
</unattend>
'@
Set-Content -Encoding UTF8 -Value $clone -Path C:\Windows\System32\Sysprep\unattend.xml

Write-Output "post-install finished; running sysprep."
Stop-Transcript

# 5. Generalise and power off. The pipeline's wait-for-vmi-status sees the VM stop.
& C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown /quiet /unattend:C:\Windows\System32\Sysprep\unattend.xml

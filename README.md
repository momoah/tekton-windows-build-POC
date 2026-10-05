# Windows SOE on OpenShift Virtualization with Tekton

**Repo:** `tekton-windows-build-POC` (separate from the Packer project `packer-windows-build`)

A tested, step-by-step guide to building a sysprepped **Windows 10 22H2** golden image inside OpenShift with **OpenShift Pipelines (Tekton)**, then creating VMs from it that boot with their own hostname, settings, grown disk and a working guest agent.

**Tested on:** single-node OpenShift, OpenShift Virtualization **4.21**, OpenShift Pipelines **1.23**, Ceph RBD (external ODF) storage, a local Quay mirror.

**Build time:** about 2½–3 hours on this lab. Creating a VM from the image: seconds, plus about 10 minutes of first boot.

---

## Contents

- [What you'll build](#what-youll-build)
- [Repo layout](#repo-layout)
- [Part A: one-time cluster setup](#part-a-one-time-cluster-setup)
- [Part B: the repo files](#part-b-the-repo-files)
- [Part C: build and use](#part-c-build-and-use)
- [Troubleshooting](#troubleshooting)
- [Lessons learned](#lessons-learned)
- [Packer vs. Tekton: three ways to build](#packer-vs-tekton-three-ways-to-build)
- [Next steps](#next-steps)

---

## What you'll build

```
ISO on Apache ─► import-win-iso ─► modify-windows-iso-file ─► create-vm ─► wait-for-vmi-status ─► create-datasource
                 create-vm-root-disk ──────────────────────────┘                (Windows installs,
                                                                                post-install.ps1,
                                                                                sysprep, power off)
finally: cleanup-vm, delete-imported-iso, delete-imported-configmaps
```

| Piece | What it is |
| --- | --- |
| `win10-soe-installer` | **Your copy** of Red Hat's `windows-efi-installer` pipeline (4.21.0), with longer time limits |
| `win10-soe-autounattend` | ConfigMap with `autounattend.xml` + `post-install.ps1` |
| `win10-soe` | The golden image: a DataVolume plus a DataSource pointing at it |
| `win10-01` | A VM cloned from the golden image, configured on first boot by Cloudbase-Init |

How it maps to the Packer project:

| Packer project | This repo |
| --- | --- |
| `packer build` | A PipelineRun of `win10-soe-installer` |
| `Autounattend.xml` on an OEMDRV CD | ConfigMap, attached as a sysprep disk |
| `scripts/setup.ps1` over WinRM | `post-install.ps1`, run by the answer file. **No WinRM** |
| Sysprep as Packer's `shutdown_command` | Sysprep as the last line of `post-install.ps1` |
| `qemu-img create -b …` | `dataVolumeTemplates` cloning from the DataSource (a full, independent copy) |
| Seed ISO built with xorriso | `cloudInitNoCloud` in the VM YAML. KubeVirt builds it and supplies `local-hostname` |

---

## Repo layout

```
tekton-windows-build-POC/
├── README.md                              # this guide
├── cluster/                               # Part A: one-time cluster setup
│   ├── pipelines-subscription.yaml
│   ├── mirror-images.sh
│   └── mirror-sets.yaml
├── autounattend/                          # Part B: what Windows runs
│   ├── autounattend.xml
│   ├── post-install.ps1
│   └── update-configmap.sh
├── pipeline/
│   └── win10-soe-installer-pipeline.yaml  # your copy of the pipeline
├── runs/
│   └── win10-soe-pipelinerun.yaml         # starts a build
├── vms/
│   └── win10-01.yaml                      # a VM from the golden image
└── scripts/
    └── watch-build.sh                     # waits for a build, then creates the VM
```

```bash
mkdir -p tekton-windows-build-POC/{cluster,autounattend,pipeline,runs,vms,scripts}
cd tekton-windows-build-POC
git init
```

The ISO **doesn't** go in the repo. It's served by Apache (Step A4).

---

## Part A: one-time cluster setup

Starting point: OpenShift with the OpenShift Virtualization operator installed.

### A1. Install OpenShift Pipelines

```bash
cat > cluster/pipelines-subscription.yaml << 'EOF'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-pipelines-operator-rh
  namespace: openshift-operators
spec:
  channel: latest
  name: openshift-pipelines-operator-rh
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
oc apply -f cluster/pipelines-subscription.yaml
```

**Check** (wait a few minutes; Tekton Results can take a minute longer):

```bash
oc get csv -n openshift-operators | grep -i pipelines   # Succeeded
oc get tektonconfig config                              # READY True
```

The web console's **Pipelines** menu is the dashboard. No separate Tekton Dashboard is needed.

**Set the pruner** so finished runs and their pods don't pile up. `oc edit tektonconfig config`, then under `spec.pruner` set `keep: 5`.

```bash
oc get tektonconfig config -o jsonpath='{.spec.pruner}'; echo
# {"disabled":false,"keep":5,"resources":["pipelinerun"],"schedule":"0 8 * * *"}
```

### A2. Storage

You need **exactly one default StorageClass**, and a **VM StorageClass with `krbd:rxbounce`**. Windows on Ceph RBD needs that map option, or it can produce data-checksum errors.

```bash
# 1. Cluster default: Ceph RBD
oc annotate storageclass ocs-external-storagecluster-ceph-rbd \
  storageclass.kubernetes.io/is-default-class=true --overwrite

# 2. A copy for VMs, with rxbounce, marked as the default for virtualization
oc get storageclass ocs-external-storagecluster-ceph-rbd -o json \
  | jq '.metadata = {
          name: "ocs-external-storagecluster-ceph-rbd-virtualization",
          annotations: {
            "description": "Ceph RBD for VMs (krbd:rxbounce)",
            "storageclass.kubevirt.io/is-default-virt-class": "true"
          }
        }
        | .parameters.mapOptions = "krbd:rxbounce"' \
  | oc create -f -
```

**Check:**

```bash
oc get storageclass      # (default) on exactly one class
oc get storageclass ocs-external-storagecluster-ceph-rbd-virtualization -o yaml \
  | grep -E 'mapOptions|is-default-virt-class'
```

Don't remove the `(default)` marker from a class without adding it to another. PVCs that don't name a class then wait forever.

### A3. Mirror the pipeline's images to Quay

The pipeline's tasks pull four images from `registry.redhat.io`. If the cluster's pull secret has no valid Red Hat login, they fail with `unauthorized`. Mirroring them to Quay avoids that.

| Image | Used by |
| --- | --- |
| `container-native-virtualization/kubevirt-tekton-tasks-create-datavolume-rhel9:v4.21.0` | Most tasks |
| `container-native-virtualization/kubevirt-tekton-tasks-disk-virt-customize-rhel9:v4.21.0` | `modify-windows-iso-file` |
| `container-native-virtualization/virtio-win-rhel9:v4.21.0` | Driver CD in the installer VM |
| `openshift4/ose-cli@sha256:3d5b31cc…2e86d` | `openshift-client` (referenced **by digest**) |

**a. Copy them** (on a host logged in to both registries: `podman login registry.redhat.io` and `podman login quay.local.labmesh.org`):

```bash
cat > cluster/mirror-images.sh << 'EOF'
#!/bin/bash
set -euo pipefail
MIRROR=quay.local.labmesh.org/mirror
SRC=registry.redhat.io/container-native-virtualization

for img in kubevirt-tekton-tasks-create-datavolume-rhel9 \
           kubevirt-tekton-tasks-disk-virt-customize-rhel9 \
           virtio-win-rhel9; do
  skopeo copy --all --preserve-digests \
    docker://$SRC/$img:v4.21.0 docker://$MIRROR/$img:v4.21.0
done

skopeo copy --all --preserve-digests \
  docker://registry.redhat.io/openshift4/ose-cli@sha256:3d5b31cc3fbf878015e5c3ed1d48379d74b15b77a1a823024a7a2b7cd5e2e86d \
  docker://$MIRROR/ose-cli:pipelines-0.2.2
EOF
chmod +x cluster/mirror-images.sh
./cluster/mirror-images.sh
```

New repositories pushed by `skopeo` are **private** in Quay.

**b. Tell the cluster to use the mirror.** Tag-referenced images need an `ImageTagMirrorSet`; digest-referenced ones need an `ImageDigestMirrorSet`.

```bash
cat > cluster/mirror-sets.yaml << 'EOF'
apiVersion: config.openshift.io/v1
kind: ImageTagMirrorSet
metadata:
  name: windows-pipeline-tags
spec:
  imageTagMirrors:
    - source: registry.redhat.io/container-native-virtualization/kubevirt-tekton-tasks-create-datavolume-rhel9
      mirrors:
        - quay.local.labmesh.org/mirror/kubevirt-tekton-tasks-create-datavolume-rhel9
    - source: registry.redhat.io/container-native-virtualization/kubevirt-tekton-tasks-disk-virt-customize-rhel9
      mirrors:
        - quay.local.labmesh.org/mirror/kubevirt-tekton-tasks-disk-virt-customize-rhel9
    - source: registry.redhat.io/container-native-virtualization/virtio-win-rhel9
      mirrors:
        - quay.local.labmesh.org/mirror/virtio-win-rhel9
---
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: windows-pipeline-digests
spec:
  imageDigestMirrors:
    - source: registry.redhat.io/openshift4/ose-cli
      mirrors:
        - quay.local.labmesh.org/mirror/ose-cli
EOF
oc apply -f cluster/mirror-sets.yaml
oc get mcp master -w        # wait for UPDATED True, UPDATING False (no reboot)
```

**c. Give the cluster a Quay login**, because the repositories are private. Use a **read-only robot account** in real use. Add both the plain host name and `:443`:

```bash
oc get secret/pull-secret -n openshift-config \
  --template='{{index .data ".dockerconfigjson" | base64decode}}' > pull-secret.json
cp pull-secret.json pull-secret.backup.json
oc registry login --registry=quay.local.labmesh.org     --auth-basic=<user>:<token> --to=pull-secret.json
oc registry login --registry=quay.local.labmesh.org:443 --auth-basic=<user>:<token> --to=pull-secret.json
oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=pull-secret.json
oc get mcp master -w        # wait for UPDATED True
rm -f pull-secret.json      # keep the backup somewhere safe, then delete it
```

**Check:** pull by the **original** name from the node. It should succeed through Quay:

```bash
NODE=$(oc get nodes -o jsonpath='{.items[0].metadata.name}')
oc debug node/$NODE -- chroot /host podman pull --authfile /var/lib/kubelet/config.json \
  registry.redhat.io/container-native-virtualization/kubevirt-tekton-tasks-create-datavolume-rhel9:v4.21.0
```

### A4. Serve the ISO permanently with Apache

The pipeline imports the ISO from an HTTP URL **on every build**, so the server must always be on.

On an always-on host (here: freighter):

```bash
sudo dnf install -y httpd
sudo mkdir -p /var/www/html/isos
sudo cp Win10_22H2_English_x64.iso /var/www/html/isos/
sudo restorecon -Rv /var/www/html/isos
sudo firewall-cmd --permanent --zone=libvirt --add-service=http   # the zone cluster traffic arrives in
sudo firewall-cmd --reload
sudo systemctl enable --now httpd
```

On a libvirt host, the cluster's traffic arrives in firewalld's **`libvirt` zone**, not the default zone.

**Check, from inside the cluster:**

```bash
oc run curltest -n default --rm -it --restart=Never \
  --image=registry.access.redhat.com/ubi9/ubi -- \
  curl -sI http://freighter.local.labmesh.org/isos/Win10_22H2_English_x64.iso
```

Expect `HTTP/1.1 200 OK` and `Content-Length: 6115186688`.

### A5. Create the project

```bash
oc new-project windows-build
```

---

## Part B: the repo files

### B1. `autounattend/autounattend.xml`

The UEFI answer file. Compared with the Packer version:

- GPT layout: EFI + MSR + Windows partitions.
- Explicit driver paths on D–G, because CD letters vary.
- **No WinRM.** `FirstLogonCommands` finds and runs `post-install.ps1` instead.

The installer VM's root disk is **virtio**, hence `viostor`.

```bash
cat > autounattend/autounattend.xml << 'EOF2'
<?xml version="1.0" encoding="utf-8"?>
<!-- KMS client setup key (GVLK) for Windows 10 Pro, published by Microsoft:
     https://learn.microsoft.com/en-us/windows-server/get-started/kms-client-activation-keys
     Selects the edition only; does not activate without a KMS host. -->
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">

  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <SetupUILanguage>
        <UILanguage>en-US</UILanguage>
        <WillShowUI>Never</WillShowUI>
      </SetupUILanguage>
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-GB</SystemLocale>
      <UserLocale>en-GB</UserLocale>
      <UILanguage>en-US</UILanguage>
    </component>

    <!-- Storage + network drivers for Setup. CD letters vary, so try D-G. -->
    <component name="Microsoft-Windows-PnpCustomizationsWinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <DriverPaths>
        <PathAndCredentials wcm:action="add" wcm:keyValue="1"><Path>D:\viostor\w10\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="2"><Path>E:\viostor\w10\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="3"><Path>F:\viostor\w10\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="4"><Path>G:\viostor\w10\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="5"><Path>D:\vioscsi\w10\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="6"><Path>E:\vioscsi\w10\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="7"><Path>F:\vioscsi\w10\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="8"><Path>G:\vioscsi\w10\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="9"><Path>D:\NetKVM\w10\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="10"><Path>E:\NetKVM\w10\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="11"><Path>F:\NetKVM\w10\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="12"><Path>G:\NetKVM\w10\amd64</Path></PathAndCredentials>
      </DriverPaths>
    </component>

    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <!-- UEFI: EFI system partition, MSR, then Windows -->
      <DiskConfiguration>
        <WillShowUI>OnError</WillShowUI>
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>100</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>3</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>
          </ModifyPartitions>
        </Disk>
      </DiskConfiguration>
      <ImageInstall>
        <OSImage>
          <InstallTo>
            <DiskID>0</DiskID>
            <PartitionID>3</PartitionID>
          </InstallTo>
          <WillShowUI>OnError</WillShowUI>
        </OSImage>
      </ImageInstall>
      <UserData>
        <AcceptEula>true</AcceptEula>
        <!-- Generic KMS client key for Windows 10 Pro (selects the edition, doesn't activate) -->
        <ProductKey>
          <Key>W269N-WFGWX-YVC9B-4J6C9-T83GX</Key>
          <WillShowUI>OnError</WillShowUI>
        </ProductKey>
      </UserData>
    </component>
  </settings>

  <!-- Stage drivers in the installed OS: network, guest-agent channel, balloon -->
  <settings pass="offlineServicing">
    <component name="Microsoft-Windows-PnpCustomizationsNonWinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <DriverPaths>
        <PathAndCredentials wcm:action="add" wcm:keyValue="1"><Path>D:\NetKVM\w10\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="2"><Path>E:\NetKVM\w10\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="3"><Path>F:\NetKVM\w10\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="4"><Path>G:\NetKVM\w10\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="5"><Path>D:\vioserial\w10\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="6"><Path>E:\vioserial\w10\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="7"><Path>F:\vioserial\w10\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="8"><Path>G:\vioserial\w10\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="9"><Path>D:\Balloon\w10\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="10"><Path>E:\Balloon\w10\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="11"><Path>F:\Balloon\w10\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="12"><Path>G:\Balloon\w10\amd64</Path></PathAndCredentials>
      </DriverPaths>
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
        <LogonCount>5</LogonCount>
        <Username>Administrator</Username>
      </AutoLogon>
      <!-- Replaces Packer's WinRM provisioning: find post-install.ps1 on the
           ConfigMap disk (letter varies) and run it. It ends with sysprep + shutdown. -->
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <CommandLine>cmd /c for %d in (D E F G H) do @if exist %d:\post-install.ps1 powershell -NoProfile -ExecutionPolicy Bypass -File %d:\post-install.ps1</CommandLine>
          <Description>Run post-install.ps1</Description>
        </SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
EOF2
xmllint --noout autounattend/autounattend.xml && echo "XML OK"
```

### B2. `autounattend/post-install.ps1`

Replaces Packer's `setup.ps1`, its two file uploads and its sysprep shutdown. It logs to `C:\Windows\Temp\post-install.log`, and **stops before sysprep on any error**, so the VM stays up for you to inspect.

**The important bit:** Cloudbase-Init is set to **Manual**, and `SetupComplete.cmd` switches it on **after** Windows setup has finished on each clone. Without this, Cloudbase-Init renamed the computer during setup, and setup then overwrote the name.

```bash
cat > autounattend/post-install.ps1 << 'EOF2'
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
# Don't start during Windows setup on clones: SetupComplete.cmd turns it on once setup has finished
Set-Service cloudbase-init -StartupType Manual
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
EOF2
head -1 autounattend/post-install.ps1   # $ErrorActionPreference = 'Stop'
tail -1 autounattend/post-install.ps1   # the sysprep.exe line
```

### B3. `autounattend/update-configmap.sh`

Creates the ConfigMap the first time, and updates it after every edit:

```bash
cat > autounattend/update-configmap.sh << 'EOF'
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
oc create configmap win10-soe-autounattend -n windows-build \
  --from-file=autounattend.xml --from-file=post-install.ps1 \
  --dry-run=client -o yaml | oc apply -f -
oc get configmap win10-soe-autounattend -n windows-build \
  -o go-template='{{range $k, $v := .data}}{{$k}}  {{len $v}} bytes{{"\n"}}{{end}}'
EOF
chmod +x autounattend/update-configmap.sh
./autounattend/update-configmap.sh
```

### B4. `pipeline/win10-soe-installer-pipeline.yaml`

Your copy of Red Hat's pipeline. Three changes:

| Line | Change | Why |
| --- | --- | --- |
| 21 | Name → `win10-soe-installer` | It's yours |
| 296 | `wait-for-vmi-status` timeout `2h` → `4h` | The stock 2-hour install limit was too short for this storage |
| 357 | `cleanup-vm` timeout `10m` → `20m` | Windows VMs can be slow to stop |

```bash
curl -fLo pipeline/win10-soe-installer-pipeline.yaml \
  https://raw.githubusercontent.com/openshift-pipelines/tektoncd-catalog/p/pipelines/windows-efi-installer/4.21.0/windows-efi-installer.yaml
sed -i -e '21s/name: windows-efi-installer/name: win10-soe-installer/' \
       -e '296s/timeout: 2h0m0s/timeout: 4h0m0s/' \
       -e '357s/timeout: 10m0s/timeout: 20m0s/' pipeline/win10-soe-installer-pipeline.yaml
sed -n '21p;296p;357p' pipeline/win10-soe-installer-pipeline.yaml
oc apply -f pipeline/win10-soe-installer-pipeline.yaml -n windows-build
```

Check the three printed lines before applying. The line numbers are for **4.21.0**, and a different version will have them elsewhere. The tasks inside still come from Red Hat's catalog (through the Quay mirror). Only the pipeline wrapper is yours.

### B5. `runs/win10-soe-pipelinerun.yaml`

```bash
cat > runs/win10-soe-pipelinerun.yaml << 'EOF'
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: win10-soe-installer-
  namespace: windows-build
spec:
  timeouts:
    pipeline: 7h0m0s
    tasks: 6h30m0s
    finally: 30m0s
  params:
    - name: winImageDownloadURL
      value: http://freighter.local.labmesh.org/isos/Win10_22H2_English_x64.iso
    - name: acceptEula
      value: "true"            # you agree to the Microsoft EULA by setting this
    - name: preferenceName
      value: windows.10.virtio
    - name: autounattendConfigMapName
      value: win10-soe-autounattend
    - name: baseDvName
      value: win10-soe         # the golden image
    - name: isoDVName
      value: win10-iso
  pipelineRef:
    name: win10-soe-installer
EOF
oc create -f runs/win10-soe-pipelinerun.yaml --dry-run=server
```

| Setting | Notes |
| --- | --- |
| `timeouts:` | **Not** `timeout:`. In Tekton `v1`, a single `timeout:` field is ignored, and the default of **1 hour** applies |
| `preferenceName: windows.10.virtio` | UEFI + Secure Boot + virtio disk. Plain `windows.10` may use BIOS |
| No `taskRunSpecs` / `securityContext` | Fixed UIDs (like 1001) are rejected by OpenShift's `restricted-v2` SCC. Let OpenShift assign them |
| No `baseDvNamespace` | The 4.21 pipeline doesn't have it. The image is created in the run's namespace |

### B6. `vms/win10-01.yaml`

```bash
cat > vms/win10-01.yaml << 'EOF'
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: win10-01
  namespace: windows-build
spec:
  runStrategy: Always
  preference:
    kind: VirtualMachineClusterPreference
    name: windows.10.virtio      # same hardware as the installer VM
  dataVolumeTemplates:
    - metadata:
        name: win10-01-root
      spec:
        sourceRef:
          kind: DataSource
          name: win10-soe
          namespace: windows-build
        storage:
          resources:
            requests:
              storage: 40Gi      # bigger than the 20Gi image; Cloudbase-Init grows C:
  template:
    spec:
      domain:
        cpu:
          sockets: 2             # the preference counts CPUs as sockets
        memory:
          guest: 4Gi
        devices:
          disks:
            - name: root
              disk: {}
            - name: seed
              cdrom: {}
          interfaces:
            - name: default
              masquerade: {}
      networks:
        - name: default
          pod: {}
      volumes:
        - name: root
          dataVolume:
            name: win10-01-root
        - name: seed
          cloudInitNoCloud:
            userData: |
              #ps1_sysnative
              Set-TimeZone -Id "UTC"
              New-Item C:\hello-from-cloudbase-init.txt
EOF
```

KubeVirt writes `meta-data` itself, as JSON, with `local-hostname` = the VM name. You only write `userData`.

### B7. `scripts/watch-build.sh`

Waits for the newest build, then creates the VM. It stops early if the build fails, and it keeps running after you close the terminal.

```bash
cat > scripts/watch-build.sh << 'EOF'
#!/bin/bash
# Usage: nohup ./scripts/watch-build.sh > build-watch.log 2>&1 &
cd "$(dirname "$0")/.."
PR=$(oc get pipelinerun -n windows-build --sort-by=.metadata.creationTimestamp \
     -o jsonpath='{.items[-1].metadata.name}')
echo "$(date) watching $PR"
while true; do
  s=$(oc get pipelinerun "$PR" -n windows-build -o jsonpath='{.status.conditions[0].status}')
  if [ "$s" = "True" ]; then
    echo "$(date) pipeline succeeded"
    oc apply -f vms/win10-01.yaml
    break
  fi
  if [ "$s" = "False" ]; then
    echo "$(date) pipeline FAILED: $(oc get pipelinerun "$PR" -n windows-build -o jsonpath='{.status.conditions[0].message}')"
    break
  fi
  sleep 300
done
EOF
chmod +x scripts/watch-build.sh
echo "build-watch.log" >> .gitignore
```

Commit:

```bash
git add . && git commit -m "Windows 10 SOE golden image pipeline for OpenShift Virtualization"
```

---

## Part C: build and use

### C1. Start a build

Before starting:

- **Keep the node quiet.** Other VMs running during the install slowed it past the time limit once.
- **If a VM from the old image exists** and you want it rebuilt, delete it first. Clones are independent copies, though, so existing VMs keep working either way.

```bash
oc create -f runs/win10-soe-pipelinerun.yaml
nohup ./scripts/watch-build.sh > build-watch.log 2>&1 &
```

### C2. Watch progress

| Phase | About | Check |
| --- | --- | --- |
| ISO import | 25 min | `oc get dv -n windows-build -w`. It sits at \~99% for \~10 min while it writes to Ceph |
| ISO rewrite | 15–45 min | `oc get taskrun -n windows-build -w \| grep modify` |
| Windows install | 1½–2 h | Web console → **Virtualization → VirtualMachines → `windows-efi-…` → Console** |
| Done | — | `cat build-watch.log`; `oc get datasource -n windows-build` |

Overall status:

```bash
oc get pipelinerun -n windows-build
oc get taskrun -n windows-build --sort-by=.metadata.creationTimestamp | tail -10
```

During the install you should see: no "press any key", no language screen, no disk picker → copying files → reboots → automatic login → a PowerShell window (`post-install.ps1`) → sysprep → power off.

### C3. Verify a VM

`watch-build.sh` creates `win10-01` when the build succeeds. Allow 10–15 minutes for first boot: Windows setup finishes, `SetupComplete.cmd` starts Cloudbase-Init, which renames the computer and reboots once.

| Check | How | Expected |
| --- | --- | --- |
| Hostname | In the VM: `hostname` | `win10-01` |
| User-data ran | `Test-Path C:\hello-from-cloudbase-init.txt`; `Get-TimeZone \| Select-Object Id` | `True`; `UTC` |
| Disk grown | `Get-Volume -DriveLetter C \| Select-Object Size` | About 42.8 GB |
| Cloudbase-Init | `Get-Service cloudbase-init \| Select-Object Status, StartType` | `Stopped` / `Automatic` (it runs at boot, then exits) |
| Guest agent | `oc get vmi win10-01 -n windows-build -o jsonpath='{.status.guestOSInfo.prettyName}'` | `Windows 10 Pro` |
| Cloudbase-Init log | Console → **Serial console** (COM1) | Plugin lines, no `CRITICAL` |

### C4. Consoles

- **Web console:** VirtualMachines → VM → **Console**. Switch between **VNC console** and **Serial console**. Use **Send key** for Ctrl+Alt+Del, and **Paste to console** to type text.
- **CLI:** `virtctl vnc <vm> -n windows-build`; `virtctl console <vm> -n windows-build` (exit: Ctrl+\]). Download a `virtctl` matching your cluster from the console's **?** → **Command Line Tools**.

### C5. Cancel a build cleanly

```bash
oc patch pipelinerun <name> -n windows-build --type merge \
  -p '{"spec":{"status":"CancelledRunFinally"}}'
```

This lets the `finally` clean-up run. Note: a cancelled run has usually already **replaced `win10-soe` with a blank disk**, so don't create VMs until a build succeeds again.

---

## Troubleshooting

Every row here happened during setup.

### Cluster and pipeline

| Symptom | Cause | Fix |
| --- | --- | --- |
| `tektonconfig` READY `False`: TektonResult | Results database still starting | Wait 2–3 min |
| PVCs `Pending` forever | No default StorageClass | Mark exactly one class `(default)` |
| TaskRun `TaskRunImagePullFailed` … `unauthorized` from `registry.redhat.io` | Pull secret has no valid Red Hat login | Mirror the images (A3) |
| Node pull: `Mirrors also failed … unauthorized` | Mirror repos are private and the cluster has no Quay login | Add Quay to the pull secret (A3c) |
| `PodAdmissionFailed` … `1001 is not an allowed group` | Fixed UIDs in `taskRunSpecs` | Remove `taskRunSpecs`; OpenShift assigns UIDs |
| Run cancelled after exactly 1 h | Used `timeout:` instead of `timeouts:` | Use `timeouts: {pipeline, tasks, finally}` |
| `wait-for-vmi-status` `TaskRunTimeout` after 2 h | Stock pipeline's fixed install limit | Your pipeline copy (B4) sets 4 h |
| ISO import `RESTARTS` climbing, `PROGRESS N/A` | ISO server unreachable | Check Apache + firewall `libvirt` zone; run the `curltest` |
| Import stuck at \~99% | Writing to Ceph after download | Wait \~10 min; follow `oc logs` of the `importer-…` pod |
| `win10-iso-…` PVC stuck `Terminating` | The finished `modify-windows-iso-file` pod still mounts it | Delete that pod; the pruner also clears it daily |
| `modify-windows-iso-file` log: `permission denied`, `tar … Cannot change mode` | Running as a random non-root UID | Harmless if the log continues to `sha256sum` |
| `oc get … -w` never ends in a script | `-w` watches forever | Use `oc wait` or `scripts/watch-build.sh` |

### VMs

| Symptom | Cause | Fix |
| --- | --- | --- |
| `insufficient CPU resources … provided as sockets` | Preference counts CPUs as sockets | Use `cpu: sockets:` not `cores:` |
| VM boots into the UEFI menu; Boot Manager shows no `Windows Boot Manager` | Image from an interrupted install | Rebuild; don't use that image |
| VM stuck `Terminating` | Long Windows grace period, or the VM sits in the firmware menu | `virtctl stop <vm> --force --grace-period=0`; then `oc delete vmi … --force`; then the `virt-launcher` pod |
| Hostname stays `WINDOWS-XXXX` though the log says `Setting hostname` | Cloudbase-Init ran during Windows setup, which overwrote the name | `SetupComplete.cmd` starts Cloudbase-Init after setup (B2) |
| `guestOSInfo` empty | `qemu-ga` not installed or running | Check `post-install.log` in the image build |

Logs inside Windows: `C:\Windows\Temp\post-install.log`, `C:\Windows\Temp\*.msi.log`, `C:\Windows\Panther\UnattendGC\setupact.log`, `C:\Windows\System32\Sysprep\Panther\setupact.log`, `C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\cloudbase-init.log`.

---

## Lessons learned

| Lesson | Where it bit |
| --- | --- |
| Read the pipeline you run. Its parameters, images and timeouts are all in the YAML | `baseDvNamespace`, the 2 h limit, the four images |
| Time limits must fit the **slowest** storage and the busiest node | Both timeout failures |
| Two first-boot processes can race. Start your own one **after** Windows setup | The hostname fix |
| A script that stops before sysprep on error leaves a VM you can inspect | `post-install.ps1` design |
| Finished pods hold volumes until they're deleted | Stuck ISO PVCs |
| Check what's actually running before blaming config | Every step had a **Check** |

---

## Packer vs. Tekton: three ways to build

There are **three** ways to combine these tools. This repo uses **B**.

|  | A. Packer on a host | B. Tekton + KubeVirt tasks (this repo) | C. Packer **inside** Tekton |
| --- | --- | --- | --- |
| Who runs the build | Packer, on freighter | Tekton tasks, in the cluster | A Tekton task that runs `packer build` |
| Where the build VM runs | QEMU on freighter | A KubeVirt VM in the cluster | A KubeVirt VM in the cluster (via the `kubevirt-iso` builder) |
| How the VM is customised | Packer connects over WinRM | The answer file runs `post-install.ps1` | Packer connects over WinRM/SSH, through the cluster |
| Where the image ends up | A qcow2 file | A DataVolume + DataSource | A DataVolume |
| Repo | `packer-windows-build` | `tekton-windows-build-POC` | Could reuse much of `packer-windows-build` |

Option C uses HashiCorp's **KubeVirt plugin for Packer** (`github.com/hashicorp/kubevirt`, builder `kubevirt-iso`), which builds images from an ISO **inside** the cluster. Its own README describes it as under development and **not production ready**, so check its status before relying on it.

---

## Next steps

1. **Store the rewritten ISO in the cluster** and drop the import and rewrite tasks from your pipeline. That saves about an hour per build and removes the Apache dependency.
2. **Pipelines as Code:** a git push to this repo starts a build.
3. **Secrets:** move the Administrator password out of the ConfigMap into a Secret, and set a different password per VM through user-data.
4. **Windows Server 2022:** `preferenceName: windows.2k22.virtio`, `2k22` driver paths, an `<InstallFrom>` edition block, and your licence key.

<#
    KONEKT OS — install it as a virtual machine.

    Unlike run-vbox.ps1, which boots the live ISO and forgets everything, this
    gives the VM its own hard disk: KONEKT OS boots from it without the CD,
    keeps your files, and keeps the updates it downloads.

        .\iso\install-vbox.ps1              # convert the disk image and boot it
        .\iso\install-vbox.ps1 -Recreate    # replace an existing VM and disk
        .\iso\install-vbox.ps1 -Headless

    Build the disk image first, from a Linux host (WSL2 is fine):

        sudo ./iso/mkdisk.sh
#>
[CmdletBinding()]
param(
    [string] $Image,
    [string] $Name     = 'KONEKT OS (installed)',
    [int]    $MemoryMB = 4096,
    [int]    $Cpus     = 2,
    [int]    $VramMB   = 128,
    [switch] $Headless,
    [switch] $Recreate
)

$ErrorActionPreference = 'Stop'
$VBoxManage = Join-Path $env:ProgramFiles 'Oracle\VirtualBox\VBoxManage.exe'
if (-not (Test-Path $VBoxManage)) { throw "VBoxManage not found at $VBoxManage — is VirtualBox installed?" }

function Invoke-VBoxQuiet {
    param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $VBoxArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $VBoxManage @VBoxArgs 2>&1 | Out-Null } catch { }
    $ErrorActionPreference = $prev
    $global:LASTEXITCODE = 0
}

$repo = Split-Path $PSScriptRoot -Parent
$dist = Join-Path $repo 'dist'

if (-not $Image) {
    $newest = Get-ChildItem -Path $dist -Filter 'konekt-os-*.img' -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $newest) { throw "No disk image in $dist — build one first:  sudo ./iso/mkdisk.sh" }
    $Image = $newest.FullName
}
if (-not (Test-Path $Image)) { throw "Disk image not found: $Image" }

$vdi = [IO.Path]::ChangeExtension($Image, '.vdi')
Write-Host "Disk image: $Image"

# ---------------------------------------------------------------- the VM
$exists = & $VBoxManage list vms | Select-String -SimpleMatch "`"$Name`""
if ($exists -and $Recreate) {
    Write-Host "Removing the previous '$Name' VM and its disk."
    Invoke-VBoxQuiet controlvm $Name poweroff
    Start-Sleep -Seconds 2
    Invoke-VBoxQuiet unregistervm $Name --delete
    $exists = $null
    if (Test-Path $vdi) { Remove-Item $vdi -Force }
}
if ($exists) {
    Write-Host "A VM called '$Name' already exists. Re-run with -Recreate to replace it."
} else {
    if (-not (Test-Path $vdi)) {
        Write-Host 'Converting the raw image to a VirtualBox disk (this takes a minute)...'
        & $VBoxManage convertfromraw $Image $vdi --format VDI
    }
    Write-Host "Creating '$Name'..."
    & $VBoxManage createvm --name $Name --ostype Debian_64 --register | Out-Null
    & $VBoxManage modifyvm $Name `
        --memory $MemoryMB --cpus $Cpus --vram $VramMB `
        --graphicscontroller vmsvga --accelerate-3d off `
        --firmware bios --rtc-use-utc off `
        --nic1 nat --audio-driver none `
        --boot1 disk --boot2 none --boot3 none --boot4 none | Out-Null
    & $VBoxManage storagectl $Name --name 'SATA' --add sata --controller IntelAhci --portcount 2 | Out-Null
    & $VBoxManage storageattach $Name --storagectl 'SATA' --port 0 --device 0 --type hdd --medium $vdi | Out-Null
}

$type = if ($Headless) { 'headless' } else { 'gui' }
Write-Host "Starting '$Name' ($type)."
& $VBoxManage setextradata $Name 'CustomVideoMode1' '1920x1080x32' 2>$null
& $VBoxManage startvm $Name --type $type | Out-Null
Start-Sleep -Seconds 4
Invoke-VBoxQuiet controlvm $Name setvideomodehint 1920 1080 32

Write-Host ''
Write-Host 'KONEKT OS is installed on its own disk now:'
Write-Host '  - it boots without the ISO'
Write-Host '  - your files, settings and downloaded updates survive a reboot'
Write-Host ''
Write-Host "  screenshot : & '$VBoxManage' controlvm '$Name' screenshotpng shot.png"
Write-Host "  power off  : & '$VBoxManage' controlvm '$Name' acpipowerbutton"

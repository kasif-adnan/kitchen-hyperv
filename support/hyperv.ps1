#requires -Version 2 -Modules Hyper-V

#implicitly import hyperv module to avoid powercli cmdlets
if((Get-Module -Name 'hyper-v') -ne $null)
{
    Remove-Module -Name hyper-v
    Import-Module -Name hyper-v
}
else
{
    Import-Module -Name hyper-v
}

$ProgressPreference = 'SilentlyContinue'


function New-DifferencingDisk
{
    [cmdletbinding()]
    param ([string[]]$Path, [string]$ParentPath)
    if (-not (Test-Path $Path))
    {
        $null = new-vhd @psboundparameters -Differencing
    }
}

function Assert-VmRunning
{
    [cmdletbinding()]
    param([string]$Id)

    if ([string]::IsNullOrEmpty($Id))
    {
        $Output = [pscustomobject]@{
            Name  = ''
            State = ''
        }
    }
    else
    {
        $Output = Get-VM -Id $Id |
        ForEach-Object -Process {
            if ($_.State -notlike 'Running')
            {
                $_ |
                Start-VM -passthru
            }
            else
            {
                $_
            }
        } |
        Select-Object -Property Name, Id, State
    }
    $Output
}

function New-KitchenVM
{
    [cmdletbinding()]
    param (
      $Generation = 1,
	    $MemoryStartupBytes,
	    $Name,
	    $Path,
	    $VHDPath,
	    $SwitchName,
	    $ProcessorCount,
      $UseDynamicMemory,
      $DynamicMemoryMinBytes,
      $DynamicMemoryMaxBytes,
      $boot_iso_path
	  )
	  $null = $psboundparameters.remove('ProcessorCount')
	  $null = $psboundparameters.remove('UseDynamicMemory')
	  $null = $psboundparameters.remove('DynamicMemoryMinBytes')
	  $null = $psboundparameters.remove('DynamicMemoryMaxBytes')
	  $null = $psboundparameters.remove('boot_iso_path')
	  $UseDynamicMemory = [Convert]::ToBoolean($UseDynamicMemory)

	  $vm = new-vm @psboundparameters |
	    Set-Vm -ProcessorCount $ProcessorCount -passthru
    if ($UseDynamicMemory) {
      $vm | Set-VMMemory -DynamicMemoryEnabled $true -MinimumBytes $DynamicMemoryMinBytes -MaximumBytes $DynamicMemoryMaxBytes
    }
    else {
      $vm | Set-VMMemory -DynamicMemoryEnabled $false
    }
      Mount-VMISO -Id $vm.Id -Path $boot_iso_path
	  $vm | Start-Vm -passthru |
	    foreach {
	      $vm = $_
	      do {
	        start-sleep -seconds 2
	      } while ($vm.state -notlike 'Running')
	      $vm
	    } |
	    select Name, Id, State
}

function Get-VmIP($vm)
{
    start-sleep -seconds 10
    $vm.networkadapters.ipaddresses |
    Where-Object {
        $_ -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$'
    } |
    Select-Object -First 1
}

Function Set-VMNetworkConfiguration
{
    [CmdletBinding()]
    Param (
        [parameter(valuefrompipeline)]
        [object]$NetworkAdapter,
        [String[]]$IPAddress = @(),
        [String[]]$Gateway = @(),
        [String[]]$DNSServers = @(),
        [String[]]$Subnet = @()
    )

    $vm = Get-WmiObject -Namespace 'root\virtualization\v2' -Class 'Msvm_ComputerSystem' | Where-Object {
        $_.ElementName -eq $NetworkAdapter.VMName
    }
    $VMSettings = $vm.GetRelated('Msvm_VirtualSystemSettingData') | Where-Object {
        $_.VirtualSystemType -eq 'Microsoft:Hyper-V:System:Realized'
    }
    $VMNetAdapters = $VMSettings.GetRelated('Msvm_SyntheticEthernetPortSettingData')

    $NetworkSettings = @()
    foreach ($NetAdapter in $VMNetAdapters)
    {
        if ($NetAdapter.Address -eq $NetworkAdapter.MacAddress)
        {
            $NetworkSettings = $NetworkSettings + $NetAdapter.GetRelated('Msvm_GuestNetworkAdapterConfiguration')
        }
    }

    $NetworkSettings[0].IPAddresses = $IPAddress
    $NetworkSettings[0].DefaultGateways = $Gateway
    $NetworkSettings[0].DNSServers = $DNSServers
    $NetworkSettings[0].Subnets = $Subnet
    $NetworkSettings[0].ProtocolIFType = 4096
    $NetworkSettings[0].DHCPEnabled = $false


    $Service = Get-WmiObject -Class 'Msvm_VirtualSystemManagementService' -Namespace 'root\virtualization\v2'
    $setIP = $Service.SetGuestNetworkAdapterConfiguration($vm, $NetworkSettings[0].GetText(1))

    if ($setIP.ReturnValue -eq 4096)
    {
        $job = [WMI]$setIP.job

        while ($job.JobState -eq 3 -or $job.JobState -eq 4)
        {
            Start-Sleep 1
            $job = [WMI]$setIP.job
        }

        if ($job.JobState -ne 7)
        {
            $job.GetError()
        }
    }
    (Get-VM -Id $NetworkAdapter.VmId).NetworkAdapter | Select-Object Name, IpAddress
}

function Get-VmDetail
{
    [cmdletbinding()]
    param($Id)

    Get-VM -Id $Id |
    ForEach-Object {
        $vm = $_
        do
        {
            Start-Sleep -Seconds 1
        }
        while (-not (Get-VmIP $vm))

        [pscustomobject]@{
            Name      = $vm.name
            Id        = $vm.ID
            IpAddress = (Get-VmIP $vm)
        }
    }
}

function Get-DefaultVMSwitch
{
    Get-VMSwitch |
    Select-Object -First 1 |
    Select-Object Name, Id
}

function Mount-VMISO
{
    [cmdletbinding()]
    param($Id, $Path)

    set-VMDvdDrive -VMName (Get-VM -Id $Id).Name -Path $Path
}

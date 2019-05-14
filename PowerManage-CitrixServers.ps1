param (
        [switch]$Debug
    )

## Constants
$evtIDPSSnapIn = 1
$evtIDNoDDC = 101
$evtIDDDCSelected = 102
$evtIDMaintOn = 201
$evtIDMaintOff = 202
$evtIDDisableMainManange = 203
$evtIDPowerOn = 301
$evtIDPoweroff = 302
$evtIDDisablePowerManange = 303
$evtIDUserMaintMode = 401
$configFile = (Get-Location).Path + "\PowerManage-CitrixServers.xml"

##Event Logs
if ((Get-EventLog "Citrix Power Manager" -Source "Power Manager") -eq $false) {
    New-EventLog -LogName "Citrix Power Manager" -Source "Power Manager"
}

try {
    Add-PSSnapin Citrix* -ErrorAction Stop
}
catch {
    Write-EventLog -LogName "Citrix Power Manager" -Source "Power Manager" -Message “Please Install the Citrix Snap-In for Powershell” -EventId $evtIDPSSnapIn -EntryType Error -Category None
    exit 0
}

try {
    Get-BrokerTag -Name "DisablePowerManage" -AdminAddress rlaw-ddc01.rlaw.local -ErrorAction stop | Out-Null
}
catch {
    New-BrokerTag -Name "DisablePowerManage" | Out-Null
    Write-Debug "Created Broker Tag 'DisablePowerManage'"
}

if (Test-Path -Path $configFile) {
    [xml]$UsageFile = Get-Content $configFile
}
else {
    $xmlwriter = New-Object System.XML.XMLTextWriter($configFile, $Null)
    $xmlWriter.Formatting = 'Indented'
    $xmlWriter.Indentation = 1
    $XmlWriter.IndentChar = "`t"
    $xmlWriter.WriteStartDocument()
        $xmlWriter.WriteStartElement('Configuration')
            $xmlWriter.WriteElementString('DeliveryGroupName', "Standard VDI")
            $xmlWriter.WriteElementString('PeakStart', "06:00")
            $xmlWriter.WriteElementString('PeakStop', "17:00")
            $xmlWriter.WriteStartElement('PeakDays')
                $xmlWriter.WriteElementString('Day', "Monday")
                $xmlWriter.WriteElementString('Day', "Tuesday")
                $xmlWriter.WriteElementString('Day', "Wednesday")
                $xmlWriter.WriteElementString('Day', "Thursday")
                $xmlWriter.WriteElementString('Day', "Friday")
            $xmlWriter.WriteEndElement()
            $xmlWriter.WriteElementString('PercentAvailableAlways', 10)
            $xmlWriter.WriteElementString('PercentAvailablePeakStart', 80)
            $xmlWriter.WriteElementString('MaxUserLoad', 10)
            $xmlWriter.WriteElementString('StartNextAtLoad', 80)
            $xmlWriter.WriteElementString('QtyStartNext', 1)
            $xmlWriter.WriteStartElement('DDC')
                $xmlWriter.WriteElementString('DDCAddress', "localhost")
                $xmlWriter.WriteElementString('DDCAddress', "ddc02.domain.local")
            $xmlWriter.WriteEndElement()
            $xmlWriter.WriteElementString('DDCPort', 80)
            $xmlWriter.WriteElementString('ServiceDelay', 60)
        $xmlWriter.WriteEndElement()
    $xmlWriter.WriteEndDocument()
    $xmlWriter.Flush()
    $xmlWriter.Close()
    [xml]$UsageFile = Get-Content $configFile
}

## Variables
$DeliveryGroupName = $UsageFile.Configuration.DeliveryGroupName
$PeakStart = $UsageFile.Configuration.PeakStart
$PeakStop = $UsageFile.Configuration.PeakStop
$PeakDays = $UsageFile.Configuration.PeakDays.Day
[int]$PercentAvailableAlways = $UsageFile.Configuration.PercentAvailableAlways
[int]$PercentAvailablePeakStart = $UsageFile.Configuration.PercentAvailablePeakStart
[int]$maxUserLoad = $UsageFile.Configuration.MaxUserLoad
[int]$startNextAtload = $UsageFile.Configuration.StartNextAtLoad
[int]$qtyStartNext = $UsageFile.Configuration.QtyStartNext
$DDC = $UsageFile.Configuration.DDC.DDCAddress
[int]$DDCPort = $UsageFile.Configuration.DDCPort
[int]$serviceDelay = $UsageFile.Configuration.ServiceDelay

## Functions
Function Is-PeakHours {
    if (($now.TimeOfDay -ge $startTime.TimeOfDay) -and ($now.TimeOfDay -lt $stopTime.TimeOfDay)) {
        if ($PeakDays -match ($now.DayOfWeek)){
            return $true
        }
    }

    return $false
}

function Get-AdminAddress ($DDCAddresses, $current) {
    if ($current) {
        if (Get-BrokerServiceStatus -AdminAddress $current -ErrorAction Continue) {
            return $current
            break
        }
    }
    else {
        foreach ($str in $DDCAddresses) {
            if (Get-BrokerServiceStatus -AdminAddress $str -ErrorAction Continue) {
                Write-EventLog -LogName "Citrix Power Manager" -Source "Power Manager" -Message “Delivery Controller $str selected” -EventId $evtIDDDCSelected -EntryType Information
                return $str
                break
            }
        }
    }

    Write-EventLog -LogName "Citrix Power Manager" -Source "Power Manager" -Message “No Delivery Controller could be reached” -EventId $evtIDNoDDC -EntryType Error
    return $false
}

function Get-DesktopCount ($ServerCount, $DDCAddress) {
    $DeliveryGroup = (Get-BrokerDesktopGroup -Name $DeliveryGroupName -AdminAddress $DDCAddress)
    $desktopsInUse = $DeliveryGroup.DesktopsAvailable + $DeliveryGroup.DesktopsInUse
    
    if (Is-PeakHours) {
        write-debug "Peak Hours"
        $MinAvailable = [math]::Ceiling($($PercentAvailablePeakStart / 100) * $ServerCount)
    } else {
        write-debug "Off-Peak Hours"
        $MinAvailable = [math]::Ceiling($($PercentAvailableAlways / 100) * $ServerCount)
    }

    $qty = [math]::Ceiling($DeliveryGroup.Sessions / $($startNextAtload / $maxUserLoad))

    if ($qty -lt $MinAvailable) {
        $qty = $MinAvailable
    }

    if ($qty -gt $ServerCount) {
        $qty = $ServerCount
    }

    write-debug "Session Count: $($DeliveryGroup.Sessions)"
    write-debug "Desktop Count: $desktopsInUse"
    write-debug "Maximum Desktop Load: $startNextAtload`%"
    write-debug "Maximum Users Per Desktop: $maxUserLoad"
    Write-Debug "Desktops in Delivery Group: $ServerCount"
    write-debug "Desktops requested: $qty"
    
    return $qty

}

## Value is either Enable or Disable
Function Set-MaintenanceMode ($server, $str, $EventID) {
    if ($str -eq "Enable") { $value = $true } else { $Value = $false }
    if ($Server.Tags -notcontains "DisablePowerManage") { 
        write-debug "$str Maintenance Mode on $($_.DNSName)"
        Get-BrokerMachine -DNSName $_.DNSName | % { Set-BrokerMachineMaintenanceMode $_ $value | Out-Null }
        Write-EventLog -LogName "Citrix Power Manager" -Source "Power Manager" -Message “$str maintenance mode for $($_.DNSName)” -EventId $EventID -EntryType Information
    }
    else {
        write-debug "Tag 'DisablePowerManage' set on $($server.DNSName)"
        Write-EventLog -LogName "Citrix Power Manager" -Source "Power Manager" -Message “Tag 'DisablePowerManage' set on $($server.DNSName)” -EventId $evtIDDisablePowerManange -EntryType Information
    }
}

## Value is either TurnOn or Shutdown
Function Set-Power ($Server, $value, $EventID) {
    if ($value -eq "TurnOn") { $str = "Turn On" } else { $str = "Shutdown" }
    if ($Server.Tags -notcontains "DisablePowerManage") { 
        write-debug "$value $($server.DNSName)"
        New-BrokerHostingPowerAction -Action $value -MachineName $server.MachineName | Out-Null
        Write-EventLog -LogName "Citrix Power Manager" -Source "Power Manager" -Message “$str $($server.DNSName)” -EventId $EventID -EntryType Information
    }
    else {
        write-debug "Tag 'DisablePowerManage' set on $($server.DNSName)"
        Write-EventLog -LogName "Citrix Power Manager" -Source "Power Manager" -Message “Tag 'DisablePowerManage' set on $($server.DNSName)” -EventId $evtIDDisablePowerManange -EntryType Information
    }
}

## Calculated variables
if ($debug) { $DebugPreference = "Continue" }
if ($serviceDelay -lt 60) { $serviceDelay = 60 }
$startTime = Get-Date $PeakStart
$stopTime = Get-Date $PeakStop
$AdminAddress = Get-AdminAddress $DDC

do {
    $AdminAddress = Get-AdminAddress $DDC $AdminAddress
    Get-logsite -AdminAddress $AdminAddress | Out-Null

    if ($AdminAddress -ne $false) {
        $now = Get-date
        write-debug (Get-Date $now -Format g)
        $Servers = Get-BrokerDesktop -DesktopGroupName $DeliveryGroupName -AdminAddress $AdminAddress | sort @{e={($_.AssociatedUserNames).Count}; a=0}, InMaintenanceMode, DNSName
        $qty = Get-DesktopCount $servers.Count $AdminAddress

        $Servers | Select -First $qty | ? { $_.InMaintenanceMode -eq $true } | % { 
            Set-MaintenanceMode $_ "Disable" $evtIDMaintOn
        }       
            
        $Servers | select -last ($servers.Count - $qty) | ? { $_.InMaintenanceMode -eq $false }| % {
            Set-MaintenanceMode $_ "Enable" $evtIDMaintOff
        }

        Start-Sleep -Seconds 5

        $Servers | % {
            if (($_.PowerState -eq "Off")  -and ( $_.InMaintenanceMode -eq $false)) {
                Set-Power $_ "TurnOn"  $evtIDPowerOn
            }
            elseif (($_.SummaryState -eq "Available") -and ($_.PowerState -eq "On") -and ( $_.InMaintenanceMode -eq $true)) {
                Set-Power $_ "Shutdown" $evtIDPowerOff
            }
        }
    }
    Start-Sleep -Seconds ($serviceDelay - 6)
} while ($true)

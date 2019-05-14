param (
        [switch]$Debug
    )

## Variables
$DeliveryGroupName = "Standard VDI" #delivery groups
$PeakStart = "06:00" #peak Start Time
$PeakStop = "19:00" #peak end time
$PeakDays = @("Monday","Tuesday","Wednesday","Thursday","Friday") #peak days
$PercentAvailableAlways = 10 #percent of servers always available
$PecentAvailablePeakStart = 80 #percent of servers available at peak start
$maxUserLoad = 10 #Max number of users per server
$startNextAtload = 80 #Max server load before starting another server 
$qtyStartNext = 1 #Start this many servers when load is reached
$DDC = @("localhost", "ddc02.domain.local")
$DDCPort = 80
$serviceDelay = 60  #Seconds

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

## Functions
Function Get-UserMaintenanceMode ($machine, $DDCAddress) {
    $CitrixSrv = ($machine.split("."))[0]
    $filter = "*$CitrixSrv*"

    $log = Get-LogHighLevelOperation -AdminAddress $DDCAddress -Filter { Text -like $filter -and Text -like "*Maintenance Mode*" }  | Sort-Object EndTime -Descending | Select -First 1
    if ($log.Text -like "Turn On Maintenance Mode*") {
        write-debug $log.Text "by" $log.User "at" $log.EndTime 
        Write-EventLog -LogName "Citrix Power Manager" -Source "Power Manager" -Message “Skipping $machine. Already in maintenance mode.” -EventId $evtIDUserMaintMode -EntryType Information
        return $true
    }

    return $false
}

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
    $load = ($DeliveryGroup.Sessions / ($maxUserLoad * $desktopsInUse)) * 100
    $reducdedLoad = ($DeliveryGroup.Sessions / ($maxUserLoad * ($desktopsInUse -$qtyStartNext))) * 100
    
    if (Is-PeakHours) {
        write-debug "Peak Hours"
        $MinAvailable = [math]::Round($ServerCount * ($PecentAvailablePeakStart / 100))
    } else {
        write-debug "Off-Peak Hours"
        $MinAvailable = [math]::Round($ServerCount * ($PercentAvailableAlways / 100))
    }

    $qty = $desktopsInUse

    if ($load -ge $startNextAtload) { 
        $qty = $desktopsInUse + $qtyStartNext
    }
    elseif ($reducdedLoad -lt $startNextAtload) {
        $qty = $desktopsInUse - $qtyStartNext
    }

    if ($qty -lt $MinAvailable) {
        $qty = $MinAvailable
    }

    if ($qty -gt $ServerCount) {
        $qty = $ServerCount
    }

    write-debug "Session Count: $($DeliveryGroup.Sessions)"
    write-debug "Desktop Count: $desktopsInUse"
    write-debug "Desktop Load: $load%"
    write-debug "Reduced Load: $reducdedLoad%"
    write-debug "Configured Maximum Desktop Load: $startNextAtload%"
    write-debug "Configured Maximum Users Per Desktop: $maxUserLoad"
    write-debug "Number of Desktops requested: $qty"
    Write-Debug "Number of Desktops in Delivery Group: $ServerCount"
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
if ($debug) {$DebugPreference = "Continue"}
$startTime = Get-Date $PeakStart
$stopTime = Get-Date $PeakStop
$AdminAddress = Get-AdminAddress $DDC

do {
    $AdminAddress = Get-AdminAddress $DDC $AdminAddress
    Get-logsite -AdminAddress $AdminAddress | Out-Null

    if ($AdminAddress -ne $false) {
        $now = Get-date
        write-debug (Get-Date $now -Format g)
        $Servers = Get-BrokerDesktop -DesktopGroupName $DeliveryGroupName -AdminAddress $AdminAddress
        $qty = Get-DesktopCount $servers.Count $AdminAddress

        $Servers | Select -First $qty | ? { $_.InMaintenanceMode -eq $true } | % { 
            Set-MaintenanceMode $_ "Disable" $evtIDMaintOn
        }       
            
        $Servers | select -last ($servers.Count - $qty) | ? { $_.InMaintenanceMode -eq $false }| % {
            Set-MaintenanceMode $_ "Enable" $evtIDMaintOff
        }

        $Servers | % {
            if (($_.PowerState -eq "Off")  -and ( $_.InMaintenanceMode -eq $false)) {
                Set-Power $_ "TurnOn"  $evtIDPowerOn
            }
            elseif (($_.SummaryState -eq "Available") -and ($_.PowerState -eq "On") -and ( $_.InMaintenanceMode -eq $true)) {
                Set-Power $_ "Shutdown" $evtIDPowerOff
            }
        }
    }
    Start-Sleep -Seconds ($serviceDelay - 1)
} while ($true)

$CLI                = 'C:\Program Files\zabbix_agent\scripts\hw.raid\CmdTool2_64.exe'
$sender             = 'C:\Program Files\zabbix_agent\zabbix_sender.exe'
$agent_config       = 'C:\Program Files\zabbix_agent\zabbix_agentd.win.conf'

$number_of_adapters = [int](& $CLI -adpCount -NoLog | Select-String "Controller Count: (\d+)" -AllMatches | % {$_.Matches} | % {$_.groups[1].value})
$physical_drives    = @()
$virtual_drives     = @()
$zsend_data         = Join-Path $(Split-Path -Parent $CLI) 'zsend_trapper_data.txt'

if (Test-Path $zsend_data) { remove-item $zsend_data }

for ($adapter = 0; $adapter -lt $number_of_adapters;$adapter++) {
    # check number of physical disks on this adapter
    $number_of_disks = [int](& $CLI -pdGetNum -a $adapter -NoLog | Select-String "Number of Physical Drives on Adapter $adapter\: (\d)" -AllMatches | % {$_.Matches} | % {$_.groups[1].value})
    if ($number_of_disks -eq 0) {
        write-host "No physical disks found on adapter $adapter. Skipping this adapter"
        Continue
    }

    # check number of configured RAID volumes
    $number_of_lds = [int](& $CLI -LDGetNum -a $adapter -NoLog | Select-String "Number of Virtual Drives Configured on Adapter $adapter\:\s(\d+)" -AllMatches | % {$_.Matches} | % {$_.groups[1].value})
    if ($number_of_lds -eq 0) {
        write-host "No virtual disks found on adapter $adapter. Skipping this adapter"
        Continue
    }

    # List Battery unit
    $bbu_is_missing = (& $CLI -AdpBbuCmd -GetBbuStatus -a $adapter -NoLog | Select-String ".*Get BBU Status Failed.*" | % {$_.Matches})
    if (!$bbu_is_missing) {
        $tmp_file = Join-Path ${env:temp} "raid_bbu-$(Get-Date -Format yyyy-MM-dd-HH-mm-ss).tmp"
        & $CLI -AdpBBUCMD -a $adapter -NoLog | Out-File $tmp_file
        $reader = [System.IO.File]::OpenText($tmp_file)
        [regex]$regex_bbu_state         = "Battery State\s*:\s(.*)$"
        [regex]$regex_state_of_charge   = "Absolute\sState\sof\scharge\s*:\s(\d+).*%"
        try {
            $writer = new-object io.streamwriter($zsend_data,$True)
            for(;;) {
                $line = $reader.ReadLine()
                if ($line -eq $null) {
                    break
                } elseif (($regex_bbu_state.isMatch($line)) -eq $True) {
                    $bbu_state          = $regex_bbu_state.Matches($line) | % {$_.groups[1].value}
                    if ($bbu_state -Match '^(Optimal|Operational)$') { $bbu_state = 0 } else { $bbu_state = 1 }
                    $writer.WriteLine("- hw.raid.bbu[$adapter,`"bbu_state`"] `"$bbu_state`"")
                } elseif ((($regex_state_of_charge.isMatch($line)) -eq $True)) {
                    $state_of_charge    = $regex_state_of_charge.Matches($line) | % {$_.groups[1].value}
                    $writer.WriteLine("- hw.raid.bbu[$adapter,`"state_of_charge`"] `"$state_of_charge`"")
                } else { Continue }
            }
        }
        finally {
            $reader.Close()
            $writer.Close()
            remove-item $tmp_file
        }
    }

    # List RAID Volumes and its states
    $tmp_file = Join-Path ${env:temp} "raid_vdrives-$(Get-Date -Format yyyy-MM-dd-HH-mm-ss).tmp"
    & $CLI -LDinfo -Lall -a $adapter -NoLog | Out-File $tmp_file
    [regex]$regex_vd_id         = "^\s*Virtual\sDrive:\s(\d+)\s.*$"
    [regex]$regex_vd_state      = "^\s*State\s+:\s(.*)$"
    $reader = [System.IO.File]::OpenText($tmp_file)
    $check_next_line = 0
    $vdrive_id  = -1;
    try {
        $writer = new-object io.streamwriter($zsend_data,$True)
        for(;;) {
            $line = $reader.ReadLine()
            if ($line -eq $null) { break }
            if (($regex_vd_id.isMatch($line)) -eq $True) {
                $vdrive_id          = $regex_vd_id.Matches($line) | % {$_.groups[1].value}
                $check_next_line    = 1
            } elseif ((($regex_vd_state.isMatch($line)) -eq $True) -and ($check_next_line -eq 1) -and ($vdrive_id -ne -1)) {
                $state              = $regex_vd_state.Matches($line) | % {$_.groups[1].value}
                if ($state -Match '^Optimal$') { $state = 0 } else { $state = 1 }
                $writer.WriteLine("- hw.raid.logical_disk[$adapter,$vdrive_id,`"vd_state`"] `"$state`"")
                $check_next_line    = -1
                $vdrive_id          = -1
            } else {
                Continue
            }
        }
    }
    finally {
        $reader.Close()
        $writer.Close()
    }
    remove-item $tmp_file

    # List physical drives
    $enclosure_number = [int](& $CLI -EncInfo -a $adapter -NoLog | Select-String "Number of enclosures on adapter $adapter -- (\d)" -AllMatches | % {$_.Matches} | % {$_.groups[1].value})
    $enclosures = @{}
    if (($enclosure_number -eq 0) -and ($number_of_disks -eq 0)) {
        write-host "No enclosures/disks detected, skipping adapter"
        Continue
    } else {
        # ========
        # List all physical drives and its states
        # ========
        $tmp_file = Join-Path ${env:temp} "raid_enclosures-$(Get-Date -Format yyyy-MM-dd-HH-mm-ss).tmp"
        & $CLI -pdlist -a $adapter -NoLog | Out-File $tmp_file
        $reader = [System.IO.File]::OpenText($tmp_file)
        $check_next_line = 0
        [regex]$regex_enc               = "^\s*Enclosure\sDevice\sID:\s(\d+)$"
        [regex]$regex_enc_na            = "^\s*Enclosure\sDevice\sID:\sN\/A$"
        [regex]$regex_slot              = "^\s*Slot\sNumber:\s(\d+)$"
        [regex]$regex_media_errors      = "Media Error Count:\s(.*)"
        [regex]$regex_predictive_errors = "Predictive Failure Count:\s(.*)"
        [regex]$regex_firmware_state    = "Firmware state:\s(.*)"
        # Determine Slot Number for each drive on enclosure
        $enclosure_id   = -1;
        $drive_id       = -1
        try {
            $writer = new-object io.streamwriter($zsend_data,$True)
            for(;;) {
                $line = $reader.ReadLine()
                if ($line -eq $null) { break }
                # Line contains enc id, next line is slot id
                if (($regex_enc.isMatch($line)) -eq $True) {
                    $enclosure_id = $regex_enc.Matches($line) | % {$_.groups[1].value}
                    $check_next_line = 1
                } elseif (($regex_enc_na.isMatch($line)) -eq $True) {
                    # This can happen, if embedded raid controller is use, there are drives and logical disks, but no enclosures
                    $enclosure_id = 2989 # 0xBAD, :( magic hack
                    $check_next_line = 1
                } elseif ((($regex_slot.isMatch($line)) -eq $True) -and ($check_next_line -eq 1) -and ($enclosure_id -ne -1)) {
                    $drive_id = $regex_slot.Matches($line) | % {$_.groups[1].value}
                    $check_next_line = 1
                } elseif    (
                                ($check_next_line -eq 1) -and
                                ($drive_id -ne -1) -and
                                ($enclosure_id -ne -1) -and
                                (($regex_media_errors.isMatch($line)) -eq $True)
                            ) {
                        $media_errors = $regex_media_errors.Matches($line) | % {$_.groups[1].value}
                        $writer.WriteLine("- hw.raid.physical_disk[$adapter,$enclosure_id,$drive_id,`"media_errors`"] $media_errors")
                        $check_next_line = 1
                } elseif    (
                                ($check_next_line -eq 1) -and
                                ($drive_id -ne -1) -and
                                ($enclosure_id -ne -1) -and
                                (($regex_predictive_errors.isMatch($line)) -eq $True)
                            ) {
                        $predictive_errors = $regex_predictive_errors.Matches($line) | % {$_.groups[1].value}
                        $writer.WriteLine("- hw.raid.physical_disk[$adapter,$enclosure_id,$drive_id,`"predictive_errors`"] $predictive_errors")
                        $check_next_line = 1
                } elseif    (
                                ($check_next_line -eq 1) -and
                                ($drive_id -ne -1) -and
                                ($enclosure_id -ne -1) -and
                                (($regex_firmware_state.isMatch($line)) -eq $True)
                            ) {
                        $firmware_state = $regex_firmware_state.Matches($line) | % {$_.groups[1].value}
                        if ($firmware_state -match '^(Unconfigured\(good\).*|Online,\sSpun.*|Hotspare,\sSpun.*)$') {
                            $firmware_state = 0
                        }
                        elseif ($firmware_state -match '^Rebuild') {
                            $firmware_state = 2
                        }
                        else {
                            $firmware_state = 1
                        }
                        $writer.WriteLine("- hw.raid.physical_disk[$adapter,$enclosure_id,$drive_id,`"firmware_state`"] `"$firmware_state`"")
                        $check_next_line = 1
                } else { Continue }
            }
        }
        finally {
            $reader.Close()
            $writer.Close()
        }
        remove-item $tmp_file
    }
}

& $sender -c $agent_config -i $zsend_data

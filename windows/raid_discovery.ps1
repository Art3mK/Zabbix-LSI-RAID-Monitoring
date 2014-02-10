$CLI                    = 'C:\Program Files\zabbix_agent\scripts\mega_cli\CmdTool2_64.exe'
$sender                 = 'C:\Program Files\zabbix_agent\zabbix_sender.exe'
$agent_config           = 'C:\Program Files\zabbix_agent\zabbix_agentd.win.conf'

$number_of_adapters     = [int](& $CLI -adpCount -NoLog | Select-String "Controller Count: (\d+)" -AllMatches | % {$_.Matches} | % {$_.groups[1].value})
$physical_drives        = @{}
$virtual_drives         = @{}
$battery_units          = @{}
$adapters               = @{}
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

	# List RAID Volumes
	for ($vd = 0;$vd -lt $number_of_lds;$vd++) {
		$virtual_drives.Add("$adapter-$vd","{ `"{#VDRIVE_ID}`":`"$vd`", `"{#ADAPTER_ID}`":`"$adapter`" }")
	}

	# List Battery unit
	$bbu_is_missing = (& $CLI -AdpBbuCmd -GetBbuStatus -a $adapter -NoLog | Select-String ".*Get BBU Status Failed.*" | % {$_.Matches})
	if (!$bbu_is_missing) {
		$battery_units.Add($adapter,"{ `"{#ADAPTER_ID}`":`"$adapter`" }")
	}

	# List physical drives
	$enclosure_number = [int](& $CLI -EncInfo -a $adapter -NoLog | Select-String "Number of enclosures on adapter $adapter -- (\d)" -AllMatches | % {$_.Matches} | % {$_.groups[1].value})
	$enclosures = @{}
	if (($enclosure_number -eq 0) -and ($number_of_disks -eq 0)) {
		write-host "No enclosures/drives detected, skipping adapter"
		Continue
	} else {
		# Detected enclosure (or no enclosure, but drives), try to add current adapter to adapters list
		if (!($adapters.ContainsKey($adapter))) {
			$adapters.Add($adapter,"{ `"{#ADAPTER_ID}`":`"$adapter`" }")
		}
		# ========
		# List all physical drives
		# ========
		$check_next_line        = 0
		[regex]$regex_enc       = "^\s*Enclosure\sDevice\sID:\s(\d+)$"
		[regex]$regex_enc_na    = "^\s*Enclosure\sDevice\sID:\sN\/A$"
		[regex]$regex_slot      = "^\s*Slot\sNumber:\s(\d+)$"

		$tmp_file   = Join-Path ${env:temp} "raid_enclosures-$(Get-Date -Format yyyy-MM-dd-HH-mm-ss).tmp"
		& $CLI -pdlist -a $adapter -NoLog | Out-File $tmp_file
		$reader     = [System.IO.File]::OpenText($tmp_file)

		# Determine Slot Number for each drive on enclosure
		$enclosure_id = -1;
		try {
			for(;;) {
				$line = $reader.ReadLine()
				if ($line -eq $null) { break }
				# Line contains enc id, next line is slot id
				if (($regex_enc.isMatch($line)) -eq $True) {
					$enclosure_id       = $regex_enc.Matches($line) | % {$_.groups[1].value}
					$check_next_line    = 1
				} elseif (($regex_enc_na.isMatch($line)) -eq $True) {
					# This can happen, if embedded raid controller is in use, there are drives and logical disks, but no enclosures
					$enclosure_id       = 2989 # 0xBAD, :( magic hack
					$check_next_line    = 1
				} elseif ((($regex_slot.isMatch($line)) -eq $True) -and ($check_next_line -eq 1) -and ($enclosure_id -ne -1)) {
					$drive_id           = $regex_slot.Matches($line) | % {$_.groups[1].value}
					$check_next_line    = 0
					$enclosure_id       = -1
					$physical_drives.Add("$adapter-$enclosure_id-$drive_id","{ `"{#ENCLOSURE_ID}`":`"$enclosure_id`", `"{#PDRIVE_ID}`":`"$drive_id`", `"{#ADAPTER_ID}`":`"$adapter`" }")
				} else {
					Continue
				}
			}
		}
		finally {
			$reader.Close()
		}
		remove-item $tmp_file
	}
}

# create file with json
$zsend_data = Join-Path $(Split-Path -Parent $CLI) 'zsend_data.txt'

if (($physical_drives.Count -ne 0) -and ($virtual_drives.Count -ne 0)) {
	$writer = new-object io.streamwriter($zsend_data,$False)
	$i = 1
	$writer.Write('- hw.raid.discovery.pdisks { "data":[')
	foreach ($physical_drive in $physical_drives.Keys) {
		if ($i -lt $physical_drives.Count) {
			$string = "$($physical_drives.Item($physical_drive)),"
		} else {
			$string = "$($physical_drives.Item($physical_drive)) ]}"
		}
		$i++
		$writer.Write($string)
	}
	$writer.WriteLine('')
	$writer.Write('- hw.raid.discovery.vdisks { "data":[')
	$i = 1
	foreach ($virtual_drive in $virtual_drives.Keys) {
		if ($i -lt $virtual_drives.Count) {
			$string = "$($virtual_drives.Item($virtual_drive)),"
		} else {
			$string = "$($virtual_drives.Item($virtual_drive)) ]}"
		}
		$i++
		$writer.Write($string)
	}
	$i = 1
	if ($battery_units.Count -ne 0) {
		$writer.WriteLine('')
		$writer.Write('- hw.raid.discovery.bbu { "data":[')
		foreach ($battery_unit in $battery_units.Keys) {
			if ($i -lt $battery_units.Count) {
				$string = "$($battery_units.Item($battery_unit)),"
			} else {
				$string = "$($battery_units.Item($battery_unit)) ]}"
			}
			$i++
			$writer.Write($string)
		}
	}
	$i = 1
	if ($adapters.Count -ne 0) {
		$writer.WriteLine('')
		$writer.Write('- hw.raid.discovery.adapters { "data":[')
		foreach ($adapter in $adapters.Keys) {
			if ($i -lt $adapters.Count) {
				$string = "$($adapters.Item($adapter)),"
			} else {
				$string = "$($adapters.Item($adapter)) ]}"
			}
			$i++
			$writer.Write($string)
		}
	}
	$writer.WriteLine('')
	$writer.Close()
}

& $sender -c $agent_config -i $zsend_data
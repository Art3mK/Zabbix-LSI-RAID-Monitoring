Param(
        [parameter(Position=0,Mandatory=$true)]
        [ValidateSet("pdisk", "vdisk", "bbu", "adapter")]
        [alias("m")]
        [String]
        $mode
    ,
        [parameter()]
        [ValidateNotNullOrEmpty()]
        [alias("p","item")]
        [string]
        $mode_item
    ,
        [parameter(Mandatory=$true)]
        [ValidateRange(0,5)]
        [alias("a","adp")]
        [int]
        $adapter
    ,
        [parameter()]
        [ValidateRange(0,4096)]
        [alias("e","enc")]
        [int]
        $enclosure_id
    ,
        [parameter()]
        [ValidateRange(0,256)]
        [alias("pdisk")]
        [int]
        $disk_id
    ,
        [parameter()]
        [ValidateRange(0,256)]
        [alias("vdisk")]
        [int]
        $vdisk_id
)

$CLI = "C:\raid\CmdTool2_64.exe"

function pdisk_item($item,$adapter,$enclosure_id,$disk_id) {
    $regex = ''
    switch ($item) {
        'firmware_state'    { $regex = "Firmware state:\s(.*)" }
        'raw_size'          { $regex = "Raw Size:\s+(\d+\.\d+\s..)" }
        'predictive_errors' { $regex = "Predictive Failure Count:\s(.*)" }
        'inquiry_data'      { $regex = "Inquiry Data:\s+(.*)" }
        'media_errors'      { $regex = "Media Error Count:\s(.*)" }
    }

    if ($enclosure_id -eq 2989) { $enclosure_id = '' }
    $output = (& $CLI -pdinfo -PhysDrv["$enclosure_id":"$disk_id"] -a $adapter -NoLog | Select-String $regex -AllMatches | % { $_.Matches } | % { $_.groups[1].value })
    if ($item -eq 'firmware_state') {
        if ($output -Match '^(Unconfigured\(good\).*|Online,\sSpun.*|Hotspare,\sSpun.*)$') {
            $output = 0
        }
        elseif ($output -Match '^Rebuild') {
            $output = 2
        }
        else {
            $output = 1
        }
    }
    write-host $output
}

function vdisk_item($item,$adapter,$vd) {
    $regex = ''
    switch ($item) {
        'vd_state'      { $regex = "^State\s+:\s(.*)$" }
        'vd_size'       { $regex = "^Size\s+:\s(\d+\.\d+\s..)" }
    }

    $output = (& $CLI -LDinfo -L $vd -a $adapter -NoLog | Select-String $regex -AllMatches | % { $_.Matches } | % { $_.groups[1].value })
    if ($item -eq 'vd_state') {
        if ($output -Match '^Optimal$') { $output = 0 } else { $output = 1 }
    }
    write-host $output
}

function bbu_item($item,$adapter){
    $regex      = ''
    $command    = ''
    switch ($item) {
        'bbu_state'         { $command = '-GetBbuStatus';       $regex = "Battery State\s*:\s(.*)$";                                    $wanted_group = 1 }
        'design_capacity'   { $command = '-GetBBUDesignInfo';   $regex = "Design\sCapacity:\s(\d+)\s(mAh|J)";                           $wanted_group = 1 }
        'full_capacity'     { $command = '-GetBBUCapacityInfo'; $regex = "(Full\sCharge\sCapacity|.*Pack\senergy\s*):\s(\d+)\s(mAh|J)"; $wanted_group = 2 }
        'state_of_charge'   { $command = '-GetBBUCapacityInfo'; $regex = "Absolute\sState\sof\scharge\s*:\s(\d+).*%";                   $wanted_group = 1 }
        'date_manufactured' { $command = '-GetBBUDesignInfo';   $regex = "Date\sof\sManufacture\s*:\s(.*)$";                            $wanted_group = 1 }
    }
    if ($bbu_state -Match '^(Optimal|Operational)$') { $bbu_state = 0 } else { $bbu_state = 1 }
    $output = (& $CLI -AdpBbuCmd $command -a $adapter -NoLog | Select-String $regex | % {$_.Matches} | % { $_.groups[$wanted_group].value })
    if ($item -eq 'bbu_state') {
        if ($output -Match '^(Optimal|Operational)$') { $output = 0 } else { $output = 1 }
    }
    write-host $output
}

function adapter_item($item,$adapter){
    $regex      = ''
    switch ($item) {
        'fw_version'        { $regex = "^\s*FW\sPackage\sBuild:\s(.*)$" }
        'product_name'      { $regex = "^\s*Product\sName\s*:\s(.*)$"   }
    }

    $output = (& $CLI -AdpAllInfo -a $adapter -NoLog | Select-String $regex  | % {$_.Matches} | % { $_.groups[1].value })
    write-host $output
}

### Start doing our job

switch ($mode) {
    "pdisk"     { pdisk_item $mode_item $adapter $enclosure_id $disk_id }
    "vdisk"     { vdisk_item $mode_item $adapter $vdisk_id }
    "bbu"       { bbu_item $mode_item $adapter }
    "adapter"   { adapter_item $mode_item $adapter }
}
